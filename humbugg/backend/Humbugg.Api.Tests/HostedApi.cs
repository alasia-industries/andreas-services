using Amazon.CognitoIdentityProvider;
using Amazon.DynamoDBv2;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.AspNetCoreServer;
using Amazon.Lambda.AspNetCoreServer.Internal;
using Amazon.Lambda.Core;
using Amazon.Lambda.TestUtilities;
using Amazon.Runtime;
using Humbugg.Api.Models;
using Humbugg.Api.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features.Authentication;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json;
using Xunit;

namespace Humbugg.Api.Tests;

/// <summary>
/// The configuration <c>Program.cs</c> reads at startup, applied once when this assembly loads.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="HumbuggSettings.FromEnvironment"/> refuses to guess a DynamoDB table name, so hosting
/// the real application in-process means the twelve variables have to exist. They are process-global
/// and this assembly has a second test class that saves, overwrites and restores the same twelve
/// (<see cref="HumbuggSettingsTests"/>). xUnit runs collections in parallel, so setting them from a
/// fixture would race that save/restore: it would capture "unset", and restoring afterwards would
/// clear them out from under a host that had not finished building.
/// </para>
/// <para>
/// A module initializer runs before any test does, which makes the ordering total instead of lucky —
/// the other class captures these values and puts these values back.
/// </para>
/// <para>
/// The Cognito ids are pinned rather than left to their defaults for the same reason in reverse: an
/// exported <c>COGNITO_CLIENT_ID</c> in a developer's shell would otherwise decide what
/// <c>OnTokenValidated</c> compares against. Nothing here reaches AWS — the tables do not exist, and
/// the tests that host the app substitute the clients that would talk to them.
/// </para>
/// </remarks>
internal static class HostedApiEnvironment
{
    public const string Region = "us-east-1";
    public const string UserPoolId = "us-east-1_testpool";
    public const string ClientId = "humbugg-test-client";
    /// <summary>An MCP host's client, accepted through <c>COGNITO_ADDITIONAL_CLIENT_IDS</c>.</summary>
    public const string McpClientId = "humbugg-test-mcp-client";

    private static readonly string[] RequiredTables =
    [
        "HUMBUGG_PROFILES_TABLE",
        "HUMBUGG_GROUPS_TABLE",
        "HUMBUGG_GROUPMEMBERS_TABLE",
        "HUMBUGG_DRAWS_TABLE",
        "HUMBUGG_AUDIT_EVENTS_TABLE",
        "HUMBUGG_ANALYTICS_EVENTS_TABLE",
        "HUMBUGG_EMAIL_MESSAGES_TABLE",
        "HUMBUGG_BILLING_TABLE",
        "HUMBUGG_WISHES_TABLE",
        "HUMBUGG_INVITATIONS_TABLE",
        "HUMBUGG_REMINDERS_TABLE",
        "HUMBUGG_TEMPLATES_TABLE",
        "HUMBUGG_QUESTIONS_TABLE",
    ];

    [ModuleInitializer]
    internal static void Apply()
    {
        foreach (var table in RequiredTables)
            Environment.SetEnvironmentVariable(table, $"unit-test-{table.ToLowerInvariant()}");

        Environment.SetEnvironmentVariable("COGNITO_REGION", Region);
        Environment.SetEnvironmentVariable("COGNITO_USER_POOL_ID", UserPoolId);
        Environment.SetEnvironmentVariable("COGNITO_CLIENT_ID", ClientId);
        Environment.SetEnvironmentVariable("COGNITO_ADDITIONAL_CLIENT_IDS", $" {McpClientId} ,");

        // Each of these switches Program.cs onto a code path that builds an AWS client or a startup
        // hosted service. Cleared so an ambient export cannot drag the unit suite towards a network.
        Environment.SetEnvironmentVariable("HUMBUGG_APP_BUCKET", null);
        Environment.SetEnvironmentVariable("S3_ENDPOINT_URL", null);
        Environment.SetEnvironmentVariable("DYNAMODB_ENDPOINT_URL", null);
        Environment.SetEnvironmentVariable("HUMBUGG_EMAIL_PROVIDER", null);
        Environment.SetEnvironmentVariable("HUMBUGG_STRIPE_MODE", null);
    }
}

/// <summary>
/// The principal API Gateway's JWT authorizer leaves on <c>HttpContext.User</c> before the ASP.NET
/// pipeline runs — built by the hosting package itself rather than imitated here.
/// </summary>
/// <remarks>
/// <para>
/// <c>Amazon.Lambda.AspNetCoreServer.APIGatewayHttpApiV2ProxyFunction.MarshallRequest</c> reads
/// <c>requestContext.authorizer.jwt.claims</c> and assigns
/// <c>new ClaimsPrincipal(new ClaimsIdentity(claims, "AuthorizerIdentity"))</c> to the request's
/// <see cref="IHttpAuthenticationFeature"/>. That method is what runs in Lambda, and it is what runs
/// below: <see cref="InvokeFeatures"/> is the same feature collection the Lambda server hands the
/// ASP.NET application, and the only thing the test supplies is the event JSON API Gateway would.
/// </para>
/// <para>
/// The Lambda server itself cannot be started in-process (it needs the Lambda Runtime API), so the
/// principal is lifted out here and installed by <see cref="GatewayAuthorizerStartupFilter"/> at the
/// same point in the request's life: before the first middleware.
/// </para>
/// </remarks>
internal static class GatewayAuthorizer
{
    /// <summary>Header carrying the authorizer's claim map, as API Gateway would have decoded it.</summary>
    public const string ClaimsHeader = "X-Test-Authorizer-Claims";

    public static ClaimsPrincipal? PrincipalFor(IDictionary<string, string> claims, IServiceProvider services)
    {
        var features = new InvokeFeatures();
        new HostFunction(services).Marshall(features, Request(claims), new TestLambdaContext());
        return ((IHttpAuthenticationFeature)features).User;
    }

    private static APIGatewayHttpApiV2ProxyRequest Request(IDictionary<string, string> claims) => new()
    {
        RawPath = "/api/me",
        RawQueryString = string.Empty,
        Headers = new Dictionary<string, string>(),
        RequestContext = new APIGatewayHttpApiV2ProxyRequest.ProxyRequestContext
        {
            DomainName = "api.humbugg.com",
            Http = new APIGatewayHttpApiV2ProxyRequest.HttpDescription
            {
                Method = "GET",
                Path = "/api/me",
                Protocol = "HTTP/1.1",
                SourceIp = "203.0.113.10"
            },
            Authorizer = new APIGatewayHttpApiV2ProxyRequest.AuthorizerDescription
            {
                Jwt = new APIGatewayHttpApiV2ProxyRequest.AuthorizerDescription.JwtDescription
                {
                    Claims = claims
                }
            }
        }
    };

    // APIGatewayHttpApiV2ProxyFunction is abstract and MarshallRequest is protected; this is the
    // smallest possible way to call the real one. The IServiceProvider constructor is the same one
    // Amazon.Lambda.AspNetCoreServer.Hosting uses for a minimal API, and it only needs a logger.
    private sealed class HostFunction(IServiceProvider services) : APIGatewayHttpApiV2ProxyFunction(services)
    {
        public void Marshall(InvokeFeatures features, APIGatewayHttpApiV2ProxyRequest request, ILambdaContext context) =>
            MarshallRequest(features, request, context);
    }
}

/// <summary>
/// Installs the gateway-supplied principal ahead of every middleware, which is where the Lambda
/// server leaves it: the feature is populated during request marshalling, before the ASP.NET
/// application is invoked at all. A startup filter is the only hook that runs earlier than
/// <c>app.UseMiddleware&lt;ApiExceptionMiddleware&gt;()</c>, the first line of the real pipeline.
/// </summary>
internal sealed class GatewayAuthorizerStartupFilter(IServiceProvider services) : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        app.Use(async (context, proceed) =>
        {
            if (context.Request.Headers.TryGetValue(GatewayAuthorizer.ClaimsHeader, out var encoded)
                && !string.IsNullOrEmpty(encoded))
            {
                var claims = JsonSerializer.Deserialize<Dictionary<string, string>>(encoded.ToString())!;
                var principal = GatewayAuthorizer.PrincipalFor(claims, services);
                if (principal is not null)
                    context.User = principal;
            }

            await proceed();
        });

        next(app);
    };
}

[CollectionDefinition("hosted-api")]
public sealed class HostedApiCollection : ICollectionFixture<HostedApiFixture>;

/// <summary>
/// The real <c>Program.cs</c> hosted in-process, with three substitutions and nothing else.
/// </summary>
/// <remarks>
/// <para>
/// The two AWS clients are replaced because constructing them resolves the ambient credential chain,
/// which a PR runner does not have; the profile service is replaced so a request that gets past
/// authorization answers <c>200</c> from memory instead of reaching a table that does not exist.
/// Authentication is untouched apart from the signing key: the Cognito key set is swapped for a
/// symmetric test key and issuer validation is off, so <c>token_use</c>, <c>client_id</c>, lifetime,
/// the challenge envelope and the authorization policy all still execute. Those are the subject.
/// </para>
/// </remarks>
public sealed class HostedApiFixture : IAsyncLifetime
{
    private static readonly SymmetricSecurityKey SigningKey = new(RandomNumberGenerator.GetBytes(32));

    private WebApplicationFactory<Program> _factory = null!;

    public ValueTask InitializeAsync()
    {
        _factory = new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services =>
            {
                services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
                {
                    // A present (empty) configuration stops the handler fetching Cognito's OIDC
                    // metadata over the network at first validation.
                    options.Configuration = new OpenIdConnectConfiguration();
                    options.TokenValidationParameters.ValidateIssuer = false;
                    options.TokenValidationParameters.IssuerSigningKey = SigningKey;
                });

                var credentials = new BasicAWSCredentials("unit-test", "unit-test");
                services.AddSingleton<IAmazonDynamoDB>(_ => new AmazonDynamoDBClient(
                    credentials,
                    new AmazonDynamoDBConfig { RegionEndpoint = Amazon.RegionEndpoint.USEast1 }));
                services.AddSingleton<IAmazonCognitoIdentityProvider>(_ => new AmazonCognitoIdentityProviderClient(
                    credentials,
                    new AmazonCognitoIdentityProviderConfig { RegionEndpoint = Amazon.RegionEndpoint.USEast1 }));
                services.AddScoped<IProfileService, StubProfileService>();

                services.AddSingleton<IStartupFilter>(provider => new GatewayAuthorizerStartupFilter(provider));
            }));

        // Force the host to build now, so a configuration failure names itself here.
        _ = _factory.Services;
        return ValueTask.CompletedTask;
    }

    public async ValueTask DisposeAsync() => await _factory.DisposeAsync();

    /// <summary>
    /// A client that sends what API Gateway sends: the bearer token, plus the authorizer's decoded
    /// claim map that the Lambda host turns into <c>HttpContext.User</c>.
    /// </summary>
    public HttpClient BehindTheGateway(string bearerToken, IDictionary<string, string> authorizerClaims)
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        client.DefaultRequestHeaders.Add(GatewayAuthorizer.ClaimsHeader, JsonSerializer.Serialize(authorizerClaims));
        return client;
    }

    /// <summary>A client with no gateway in front of it — local Kestrel, or an anonymous route.</summary>
    public HttpClient Direct() => _factory.CreateClient();

    /// <summary>A Cognito access token, or — by overriding the claims — one the app must refuse.</summary>
    public static string MintToken(string sub, string tokenUse = "access", string? clientId = null)
    {
        var now = DateTime.UtcNow;
        var claims = new Dictionary<string, object>
        {
            ["sub"] = sub,
            ["token_use"] = tokenUse
        };

        // Cognito puts client_id on an access token and aud on an ID token. Reproducing that split is
        // the whole point of the ID-token case: aud alone satisfies the gateway's JWT authorizer.
        if (tokenUse == "access")
            claims["client_id"] = clientId ?? HostedApiEnvironment.ClientId;
        else
            claims["aud"] = clientId ?? HostedApiEnvironment.ClientId;

        return new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = $"https://cognito-idp.{HostedApiEnvironment.Region}.amazonaws.com/{HostedApiEnvironment.UserPoolId}",
            IssuedAt = now - TimeSpan.FromMinutes(5),
            NotBefore = now - TimeSpan.FromMinutes(5),
            Expires = now + TimeSpan.FromHours(1),
            SigningCredentials = new SigningCredentials(SigningKey, SecurityAlgorithms.HmacSha256),
            Claims = claims
        });
    }

    private sealed class StubProfileService(ICurrentUser user) : IProfileService
    {
        private Profile Mine => new(user.UserId, "Unit Test", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z");

        public Task<Profile> GetAsync(CancellationToken cancellationToken = default) => Task.FromResult(Mine);
        public Task<Profile> SaveAsync(SaveProfileRequest request, CancellationToken cancellationToken = default) => Task.FromResult(Mine);
        public Task<Profile> UploadAvatarAsync(UploadAvatarRequest request, CancellationToken cancellationToken = default) => Task.FromResult(Mine);
        public Task<Profile> RemoveAvatarAsync(CancellationToken cancellationToken = default) => Task.FromResult(Mine);
    }
}
