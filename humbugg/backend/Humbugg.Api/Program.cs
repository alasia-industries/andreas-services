using Amazon.ApiGatewayManagementApi;
using Amazon.DynamoDBv2;
using Amazon.Lambda.AspNetCoreServer.Hosting;
using Amazon.Runtime.Credentials;
using Humbugg.Api.Consumers;
using Humbugg.Api.Data;
using Humbugg.Api.Middleware;
using Humbugg.Api.Services;
using Humbugg.Api.Services.Email.Adapters.Aws;
using Humbugg.Api.Services.Email.Adapters.Http;
using Humbugg.Api.Services.Email.Adapters.Memory;
using Humbugg.Api.Services.Email.Core;
using Humbugg.Api.Services.Realtime;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.IdentityModel.Tokens;
using System.Text.Json;
using System.Text.Json.Serialization;

// ─── Background consumer hosting ────────────────────────────────────────────
// Consumer Lambdas use this executable but do not start the ASP.NET Core API.
// ConsumerHost is the single registry for all current and future consumers.
if (ConsumerHost.IsConsumerProcess)
{
    await ConsumerHost.RunConfiguredAsync();
    return;
}

// ─── HTTP API hosting ────────────────────────────────────────────────────────
var builder = WebApplication.CreateBuilder(args);
var settings = HumbuggSettings.FromEnvironment();
builder.Services.AddSingleton(settings);
builder.Services.AddSingleton<IPlanCatalog>(PlanCatalog.FromEnvironment());
builder.Services.AddSingleton(AnalyticsOptions.FromEnvironment());
// Validates Stripe billing configuration at startup: fails fast on missing test-mode
// credentials and refuses any live-mode key/mode (blocked pending issue #159).
builder.Services.AddSingleton(StripeSettings.FromEnvironment());

builder.Services.AddControllers().AddJsonOptions(options =>
{
    options.JsonSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
    options.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    options.JsonSerializerOptions.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower));
});
builder.Services.AddProblemDetails();
builder.Services.Configure<ApiBehaviorOptions>(options =>
{
    options.InvalidModelStateResponseFactory = _ => new BadRequestObjectResult(new
    {
        error = new { code = "bad_request", message = "The request body is invalid." }
    });
});
builder.Services.AddHttpContextAccessor();
// The API answers on its own domain (api.humbugg.com), so every browser request is
// cross-origin and CORS is load-bearing rather than decorative. ASP.NET is the single
// source of the Access-Control-* headers — API Gateway deliberately emits none of its
// own, because a browser rejects a response carrying two Allow-Origin headers.
builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
    policy.WithOrigins(settings.CorsOrigins).AllowAnyHeader().AllowAnyMethod()));

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
{
    options.Authority = $"https://cognito-idp.{settings.CognitoRegion}.amazonaws.com/{settings.CognitoUserPoolId}";
    options.RequireHttpsMetadata = true;
    options.MapInboundClaims = false;
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidateAudience = false,
        ValidateLifetime = true,
        NameClaimType = "sub"
    };
    options.Events = new JwtBearerEvents
    {
        OnTokenValidated = context =>
        {
            var tokenUse = context.Principal?.FindFirst("token_use")?.Value;
            var clientId = context.Principal?.FindFirst("client_id")?.Value;
            // The app client, or one of the MCP hosts' clients (COGNITO_ADDITIONAL_CLIENT_IDS):
            // the MCP server calls this API as the signed-in person with its host's token.
            if (tokenUse != "access" || !settings.AcceptsClientId(clientId))
                context.Fail("The token is not a valid Humbugg access token.");
            return Task.CompletedTask;
        },
        OnChallenge = async context =>
        {
            context.HandleResponse();
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { error = new { code = "unauthorized", message = "A valid Cognito access token is required." } });
        },
        OnForbidden = context =>
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return context.Response.WriteAsJsonAsync(new { error = new { code = "forbidden", message = "You do not have permission to perform this action." } });
        }
    };
});
// The default policy names JwtBearer explicitly, and that is load-bearing rather than tidy (#656).
//
// Behind API Gateway the application is not the first thing to set HttpContext.User:
// Amazon.Lambda.AspNetCoreServer marshals requestContext.authorizer.jwt.claims into a
// ClaimsPrincipal with the authentication type "AuthorizerIdentity" and assigns it to the
// IHttpAuthenticationFeature before the ASP.NET pipeline runs at all
// (APIGatewayHttpApiV2ProxyFunction.MarshallRequest). An identity with an authentication type is
// authenticated, and the HTTP API's JWT authorizer takes an ID token as readily as an access one
// because their audience is the same app client.
//
// A schemeless default policy leaves that principal alone: UseAuthentication does not overwrite
// HttpContext.User when the handler returns a failure carrying no principal, and the authorization
// middleware only re-authenticates when the policy names schemes. The OnTokenValidated rule above
// therefore ran, failed, and changed nothing — prod answered an ID token exactly as it answered an
// access token. Naming the scheme makes the authorization middleware authenticate against
// JwtBearer and replace HttpContext.User with that result, so a failed validation is a 401 whatever
// the host put there.
//
// DefaultPolicy only, deliberately: a FallbackPolicy would also cover endpoints carrying no
// authorization metadata at all, which is what /health is.
builder.Services.AddAuthorization(options =>
    options.DefaultPolicy = new AuthorizationPolicyBuilder(JwtBearerDefaults.AuthenticationScheme)
        .RequireAuthenticatedUser()
        .Build());

builder.Services.AddSingleton<IAmazonDynamoDB>(_ =>
{
    var config = new AmazonDynamoDBConfig { RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(settings.AwsRegion) };
    if (!string.IsNullOrWhiteSpace(settings.DynamoDbEndpointUrl))
    {
        config.ServiceURL = settings.DynamoDbEndpointUrl;
        config.UseHttp = settings.DynamoDbEndpointUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
        config.AuthenticationRegion = settings.AwsRegion;
    }
    return new AmazonDynamoDBClient(config);
});
// The verified email address behind an account (#137). Humbugg stores none of its own; Cognito is
// the only place a verified one exists, and the directory below is the only thing that reads it.
builder.Services.AddSingleton<Amazon.CognitoIdentityProvider.IAmazonCognitoIdentityProvider>(_ =>
    new Amazon.CognitoIdentityProvider.AmazonCognitoIdentityProviderClient(
        new Amazon.CognitoIdentityProvider.AmazonCognitoIdentityProviderConfig
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(settings.CognitoRegion),
        }));
builder.Services.AddScoped<IAccountDirectory, CognitoAccountDirectory>();

// Avatar object storage. When an application bucket is configured the backend writes to S3 and
// CloudFront serves production objects read-only. With no bucket configured (unit tests), an
// in-process store keeps the upload flow working without any AWS dependency.
if (!string.IsNullOrWhiteSpace(settings.AppBucket))
{
    builder.Services.AddSingleton<Amazon.S3.IAmazonS3>(_ =>
    {
        var s3Config = new Amazon.S3.AmazonS3Config
        {
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(settings.AwsRegion)
        };
        if (!string.IsNullOrWhiteSpace(settings.S3EndpointUrl))
        {
            // Optional S3-compatible endpoint support. Path-style addressing is required because
            // virtual-host-style bucket hostnames generally do not resolve for custom endpoints.
            s3Config.ServiceURL = settings.S3EndpointUrl;
            s3Config.ForcePathStyle = true;
            s3Config.UseHttp = settings.S3EndpointUrl.StartsWith("http://", StringComparison.OrdinalIgnoreCase);
            s3Config.AuthenticationRegion = settings.AwsRegion;
        }
        return new Amazon.S3.AmazonS3Client(s3Config);
    });
    builder.Services.AddScoped<IAvatarStore, S3AvatarStore>();
    // Custom S3-compatible endpoints may start empty; ensure the configured bucket exists. This never
    // runs against AWS because AWS-backed development and production buckets are created by Terraform.
    if (!string.IsNullOrWhiteSpace(settings.S3EndpointUrl))
        builder.Services.AddHostedService<S3Bootstrap>();
}
else
{
    builder.Services.AddSingleton<IAvatarStore, InMemoryAvatarStore>();
}
builder.Services.AddSingleton<ITransactionalEmailTemplates, TransactionalEmailTemplates>();
if (settings.EmailProvider.Equals("mailer", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddSingleton<IMailerRequestSigner>(_ =>
    {
        if (settings.MailerAuthMode.Equals("none", StringComparison.OrdinalIgnoreCase))
            return new UnsignedMailerRequestSigner();
        if (settings.MailerAuthMode.Equals("sigv4", StringComparison.OrdinalIgnoreCase))
        {
            return new AwsSigV4MailerRequestSigner(
                DefaultAWSCredentialsIdentityResolver.GetCredentials(
                    new AmazonDynamoDBConfig
                    {
                        RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(settings.AwsRegion)
                    }),
                settings.AwsRegion);
        }
        throw new InvalidOperationException(
            $"Unsupported HUMBUGG_MAILER_AUTH_MODE '{settings.MailerAuthMode}'.");
    });
    builder.Services.AddHttpClient<IMailerClient, MailerClient>(client =>
    {
        client.BaseAddress = new Uri(settings.MailerBaseUrl, UriKind.Absolute);
        client.Timeout = TimeSpan.FromSeconds(15);
    });
    builder.Services.AddScoped<IEmailTransport, MailerEmailTransport>();
    builder.Services.AddScoped<IEmailDeliveryLedger, DynamoDbEmailDeliveryLedger>();
}
else if (settings.EmailProvider.Equals("capture", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddSingleton<CapturingEmailTransport>();
    builder.Services.AddSingleton<IEmailTransport>(services => services.GetRequiredService<CapturingEmailTransport>());
    builder.Services.AddSingleton<IEmailDeliveryLedger, InMemoryEmailDeliveryLedger>();
}
else
{
    throw new InvalidOperationException($"Unsupported HUMBUGG_EMAIL_PROVIDER '{settings.EmailProvider}'.");
}
// Gates non-essential product email on the recipient's account opt-out; essential mail always sends.
builder.Services.AddScoped<IEmailPreferenceGate, AccountEmailPreferenceGate>();
builder.Services.AddScoped<ITransactionalEmailService, TransactionalEmailService>();
builder.Services.AddScoped<IProfileRepository, ProfileRepository>();
builder.Services.AddScoped<IGroupRepository, GroupRepository>();
builder.Services.AddScoped<ITemplateRepository, TemplateRepository>();
builder.Services.AddScoped<IMembershipRepository, MembershipRepository>();
builder.Services.AddScoped<IWishRepository, WishRepository>();
builder.Services.AddScoped<IQuestionRepository, QuestionRepository>();
// The realtime channel (#691). One store and one notifier for the process: connections are shared
// state, and the in-process hub IS the state when the container hosts the sockets itself.
if (settings.RealtimeViaApiGateway)
{
    if (string.IsNullOrWhiteSpace(settings.ChatConnectionsTable))
        throw new InvalidOperationException("HUMBUGG_CHAT_CONNECTIONS_TABLE is required when HUMBUGG_REALTIME_ENDPOINT is set.");
    builder.Services.AddSingleton<IRealtimeConnectionStore>(services =>
        new DynamoDbRealtimeConnectionStore(services.GetRequiredService<IAmazonDynamoDB>(), settings.ChatConnectionsTable));
    builder.Services.AddSingleton<IAmazonApiGatewayManagementApi>(_ =>
        new AmazonApiGatewayManagementApiClient(new AmazonApiGatewayManagementApiConfig
        {
            ServiceURL = settings.RealtimeEndpoint,
            RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(settings.AwsRegion)
        }));
    builder.Services.AddSingleton<IRealtimeNotifier, ApiGatewayRealtimeNotifier>();
}
else
{
    builder.Services.AddSingleton<IRealtimeConnectionStore, InMemoryRealtimeConnectionStore>();
    builder.Services.AddSingleton<InProcessRealtimeHub>();
    builder.Services.AddSingleton<IRealtimeNotifier>(services => services.GetRequiredService<InProcessRealtimeHub>());
}
builder.Services.AddScoped<IRealtimeTicketService, RealtimeTicketService>();
builder.Services.AddScoped<IInvitationRepository, InvitationRepository>();
builder.Services.AddScoped<IReminderRepository, ReminderRepository>();
builder.Services.AddScoped<IAuditRepository, AuditRepository>();
builder.Services.AddScoped<IAuditActorAnonymizer, AuditActorAnonymizer>();
builder.Services.AddScoped<IAnalyticsSink, DynamoDbAnalyticsSink>();
builder.Services.AddScoped<IBillingRepository, BillingRepository>();
builder.Services.AddScoped<ICurrentUser, CurrentUser>();
builder.Services.AddScoped<IRequestCorrelation, HttpRequestCorrelation>();
builder.Services.AddScoped<IAuditTrail, AuditTrail>();
builder.Services.AddScoped<IProductAnalytics, ProductAnalytics>();
builder.Services.AddScoped<IProfileService, ProfileService>();
builder.Services.AddScoped<IGroupService, GroupService>();
builder.Services.AddScoped<IWishService, WishService>();
// Reading a pasted product link (#129). The handler is the security boundary, not the caller: its
// ConnectCallback resolves the host, refuses every non-public answer and dials the address it just
// approved, which is what closes the gap a separate "validate then fetch" leaves open to DNS
// rebinding. Redirects are followed by hand in the service so each hop is re-judged.
builder.Services.AddHttpClient(WishPreviewService.ClientName, client =>
    {
        client.Timeout = WishPreviewService.Timeout;
        client.MaxResponseContentBufferSize = WishPreviewService.MaxBytes;
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Humbugg-LinkPreview/1.0 (+https://humbugg.com)");
    })
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        ConnectCallback = async (context, cancellationToken) =>
            await WishUrlSafety.ConnectAsync(context.DnsEndPoint, cancellationToken),
        ConnectTimeout = TimeSpan.FromSeconds(3),
        // No cookie jar and no credentials: this fetches public pages on nobody's behalf.
        UseCookies = false,
        Credentials = null,
    });
builder.Services.AddScoped<IWishPreviewService, WishPreviewService>();
builder.Services.AddScoped<IQuestionService, QuestionService>();
builder.Services.AddScoped<IInvitationService, InvitationService>();
builder.Services.AddScoped<ILateParticipantService, LateParticipantService>();
builder.Services.AddScoped<ReminderService>();
builder.Services.AddScoped<IReminderService>(services => services.GetRequiredService<ReminderService>());
builder.Services.AddScoped<IReminderProcessor>(services => services.GetRequiredService<ReminderService>());
builder.Services.AddScoped<IExchangeTemplateService, ExchangeTemplateService>();
builder.Services.AddScoped<IAccountDeletionService, AccountDeletionService>();
builder.Services.AddScoped<IDataExportService, DataExportService>();
builder.Services.AddScoped<IBillingService, BillingService>();
builder.Services.AddSingleton<IStripeGateway, StripeGateway>();
builder.Services.AddSingleton<IMatchingService, MatchingService>();
if (!string.IsNullOrWhiteSpace(settings.DynamoDbEndpointUrl))
    builder.Services.AddHostedService<DynamoDbBootstrap>();
builder.Services.AddAWSLambdaHosting(LambdaEventSource.HttpApi);

var app = builder.Build();
app.UseMiddleware<ApiExceptionMiddleware>();
app.UseCors();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();
// Rate limiting is enforced upstream at the API Gateway stage (default route throttling),
// not in-process — see humbugg/infra/modules/compute and humbugg/docs/threat-model.md §4.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapControllers();
// The container's own socket endpoint, where it hosts the channel itself (#691). Not in a Lambda:
// an HTTP API cannot upgrade a connection, and production's sockets are API Gateway's. The ticket
// is the credential — spent here exactly as the $connect authorizer spends it in production.
if (!settings.RealtimeViaApiGateway)
{
    app.UseWebSockets();
    app.Map("/ws", async context =>
    {
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = 400; return; }
        var store = context.RequestServices.GetRequiredService<IRealtimeConnectionStore>();
        var ticket = context.Request.Query["ticket"].ToString();
        var userId = string.IsNullOrWhiteSpace(ticket) ? null : await store.ConsumeTicketAsync(ticket, DateTimeOffset.UtcNow);
        if (userId is null) { context.Response.StatusCode = 401; return; }
        using var socket = await context.WebSockets.AcceptWebSocketAsync();
        await context.RequestServices.GetRequiredService<InProcessRealtimeHub>().RunAsync(userId, socket, context.RequestAborted);
    });
}
app.Run();

public partial class Program;

public sealed record HumbuggSettings(
    string AwsRegion,
    string CognitoRegion,
    string CognitoUserPoolId,
    string CognitoClientId,
    string[] CorsOrigins,
    string AppBaseUrl,
    string? DynamoDbEndpointUrl,
    string ProfilesTable,
    string GroupsTable,
    string GroupMembersTable,
    string DrawsTable,
    string AuditEventsTable,
    string AnalyticsEventsTable,
    string EmailProvider = "capture",
    string EmailMessagesTable = "humbugg-email-messages",
    string MailerBaseUrl = "http://host.docker.internal:8026",
    string MailerAuthMode = "none",
    string MailerServiceId = "humbugg",
    string AppBucket = "",
    string AvatarBaseUrl = "http://localhost:8081",
    string? S3EndpointUrl = null,
    string BillingRecordsTable = "humbugg-billing",
    string WishesTable = "humbugg-wishes",
    string InvitationsTable = "humbugg-invitations",
    string RemindersTable = "humbugg-reminders",
    string TemplatesTable = "humbugg-templates",
    string QuestionsTable = "humbugg-questions",
    // The realtime channel (#691). In production the endpoint is the WebSocket API's management
    // URL and the table holds connections and tickets; unset, the container hosts the sockets
    // itself on /ws and keeps both in memory — the dev stack, and the tests.
    string? RealtimeEndpoint = null,
    string ChatConnectionsTable = "",
    // Cognito app clients accepted beside CognitoClientId — one per MCP host (humbugg/mcp). The
    // gateway authorizer's audience lists the same clients (infra/modules/compute); a client in
    // one list and not the other is refused by whichever lacks it.
    string[]? CognitoAdditionalClientIds = null)
{
    public bool RealtimeViaApiGateway => !string.IsNullOrWhiteSpace(RealtimeEndpoint);

    /// <summary>
    /// Whether an access token's <c>client_id</c> is one this API serves: the app client or an
    /// MCP host's. Exact, ordinal match; a missing claim is never accepted.
    /// </summary>
    public bool AcceptsClientId(string? clientId) =>
        !string.IsNullOrEmpty(clientId)
        && (string.Equals(clientId, CognitoClientId, StringComparison.Ordinal)
            || (CognitoAdditionalClientIds ?? []).Contains(clientId, StringComparer.Ordinal));

    public static HumbuggSettings FromEnvironment()
    {
        // The product app's dev origin. Not :5176 — that is the marketing site, which has no
        // /join or /organize route; the link the backend mints has to land in the app.
        var appBaseUrl = (Environment.GetEnvironmentVariable("APP_BASE_URL") ?? "http://localhost:8081").TrimEnd('/');
        return new(
            Environment.GetEnvironmentVariable("AWS_REGION") ?? Environment.GetEnvironmentVariable("AWS_DEFAULT_REGION") ?? "us-east-1",
            Environment.GetEnvironmentVariable("COGNITO_REGION") ?? "us-east-1",
            Environment.GetEnvironmentVariable("COGNITO_USER_POOL_ID") ?? "us-east-1_example",
            Environment.GetEnvironmentVariable("COGNITO_CLIENT_ID") ?? "humbugg-web",
            ParseCorsOrigins(Environment.GetEnvironmentVariable("CORS_ORIGINS")),
            appBaseUrl,
            Environment.GetEnvironmentVariable("DYNAMODB_ENDPOINT_URL"),
            RequiredTable("HUMBUGG_PROFILES_TABLE"),
            RequiredTable("HUMBUGG_GROUPS_TABLE"),
            RequiredTable("HUMBUGG_GROUPMEMBERS_TABLE"),
            RequiredTable("HUMBUGG_DRAWS_TABLE"),
            RequiredTable("HUMBUGG_AUDIT_EVENTS_TABLE"),
            RequiredTable("HUMBUGG_ANALYTICS_EVENTS_TABLE"),
            Environment.GetEnvironmentVariable("HUMBUGG_EMAIL_PROVIDER") ?? "capture",
            RequiredTable("HUMBUGG_EMAIL_MESSAGES_TABLE"),
            (Environment.GetEnvironmentVariable("HUMBUGG_MAILER_BASE_URL") ??
                "http://host.docker.internal:8026").TrimEnd('/'),
            Environment.GetEnvironmentVariable("HUMBUGG_MAILER_AUTH_MODE") ?? "none",
            Environment.GetEnvironmentVariable("HUMBUGG_MAILER_SERVICE_ID") ?? "humbugg",
            Environment.GetEnvironmentVariable("HUMBUGG_APP_BUCKET") ?? "",
            (Environment.GetEnvironmentVariable("HUMBUGG_AVATAR_BASE_URL")?.TrimEnd('/')) ?? appBaseUrl,
            Environment.GetEnvironmentVariable("S3_ENDPOINT_URL"),
            RequiredTable("HUMBUGG_BILLING_TABLE"),
            RequiredTable("HUMBUGG_WISHES_TABLE"),
            RequiredTable("HUMBUGG_INVITATIONS_TABLE"),
            RequiredTable("HUMBUGG_REMINDERS_TABLE"),
            RequiredTable("HUMBUGG_TEMPLATES_TABLE"),
            RequiredTable("HUMBUGG_QUESTIONS_TABLE"),
            Environment.GetEnvironmentVariable("HUMBUGG_REALTIME_ENDPOINT")?.TrimEnd('/'),
            Environment.GetEnvironmentVariable("HUMBUGG_CHAT_CONNECTIONS_TABLE") ?? "",
            ParseClientIds(Environment.GetEnvironmentVariable("COGNITO_ADDITIONAL_CLIENT_IDS")));
    }

    // Comma-separated, like CORS_ORIGINS, because Lambda env vars are flat strings. Unset or blank
    // is no additional client: the app client alone, which is what every stack had before MCP.
    internal static string[] ParseClientIds(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? []
            : value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    // Table names are per-environment and carry no safe default: prod, each
    // developer's isolated dev stack, and any future environment all name them
    // differently. Substituting a guess for a missing variable points the
    // service at a table that does not exist and turns a misconfigured deploy
    // into a runtime failure far from its cause. Two of the names this used to
    // fall back to (humbugg-audit-events, humbugg-billing) were pre-rename
    // tables that have since been deleted outright.
    //
    // The deploy workflow sets all twelve; dev-aws-setup.sh writes all twelve
    // into ~/.config/andreas-services/humbugg/dev.env from Terraform outputs. A missing one means the
    // environment is genuinely misconfigured, so fail at startup and say which.
    private static string RequiredTable(string variable) =>
        Environment.GetEnvironmentVariable(variable) is { } value && !string.IsNullOrWhiteSpace(value)
            ? value.Trim()
            : throw new InvalidOperationException(
                $"{variable} is not set. DynamoDB table names are per-environment and have no default. " +
                "In CI the deploy workflow sets it; locally run humbugg/scripts/dev-aws-setup.sh, " +
                "which writes the table names from Terraform outputs into ~/.config/andreas-services/humbugg/dev.env.");

    // Local development runs two distinct browser origins against one backend: the Vite
    // marketing dev server on :5176 and the Expo web dev server on :8081.
    private static readonly string[] DefaultCorsOrigins =
        ["http://localhost:5176", "http://localhost:8081"];

    // CORS_ORIGINS is a comma-separated list because the surfaces that call this API live on
    // separate hosts (www., app., and both dev servers) and Lambda env vars are flat strings.
    private static string[] ParseCorsOrigins(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return DefaultCorsOrigins;
        var origins = value.Split(
            ',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return origins.Length > 0 ? origins : DefaultCorsOrigins;
    }
}
