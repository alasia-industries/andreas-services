using System.Net;
using Xunit;

namespace Humbugg.Api.Tests;

/// <summary>
/// The API serves more than one Cognito app client: the product app's, and one per MCP host
/// (humbugg/mcp), which calls this API as the signed-in person with the token its host holds.
/// </summary>
/// <remarks>
/// <c>OnTokenValidated</c> compared <c>client_id</c> to the app client alone, so every MCP tool call
/// would have been a 401 from the application even after the gateway's audience let it in. The
/// allow-list is <c>COGNITO_CLIENT_ID</c> plus <c>COGNITO_ADDITIONAL_CLIENT_IDS</c>; the hosted cases
/// run the real <c>Program.cs</c> behind the real gateway marshaller (<see cref="HostedApiFixture"/>),
/// with the environment <see cref="HostedApiEnvironment"/> pins — including a padded, trailing-comma
/// list, which is what a hand-edited dev.env produces.
/// </remarks>
[Collection("hosted-api")]
public sealed class CognitoClientAllowListTests(HostedApiFixture api)
{
    private const string Subject = "66666666-7777-8888-9999-000000000000";

    private static Dictionary<string, string> AccessTokenClaims(string clientId) => new()
    {
        ["sub"] = Subject,
        ["token_use"] = "access",
        ["client_id"] = clientId,
        ["scope"] = "openid email profile"
    };

    [Fact]
    public async Task An_mcp_hosts_access_token_reaches_the_application()
    {
        using var client = api.BehindTheGateway(
            HostedApiFixture.MintToken(Subject, clientId: HostedApiEnvironment.McpClientId),
            AccessTokenClaims(HostedApiEnvironment.McpClientId));

        var response = await client.GetAsync("/api/me", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    /// <summary>The allow-list widens which clients, never which token type.</summary>
    [Fact]
    public async Task An_mcp_hosts_id_token_is_still_refused()
    {
        var claims = new Dictionary<string, string>
        {
            ["sub"] = Subject,
            ["token_use"] = "id",
            ["aud"] = HostedApiEnvironment.McpClientId
        };
        using var client = api.BehindTheGateway(
            HostedApiFixture.MintToken(Subject, tokenUse: "id", clientId: HostedApiEnvironment.McpClientId),
            claims);

        var response = await client.GetAsync("/api/me", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task A_client_on_neither_list_is_still_refused()
    {
        using var client = api.BehindTheGateway(
            HostedApiFixture.MintToken(Subject, clientId: "not-an-mcp-host"),
            AccessTokenClaims("not-an-mcp-host"));

        var response = await client.GetAsync("/api/me", TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Theory]
    [InlineData("app-client", true)]
    [InlineData("mcp-claude", true)]
    [InlineData("mcp-smoke", true)]
    [InlineData("MCP-CLAUDE", false)]
    [InlineData("mcp-claud", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Accepts_exactly_the_app_client_and_the_additional_ones(string? clientId, bool accepted)
    {
        var settings = Settings(additional: ["mcp-claude", "mcp-smoke"]);

        Assert.Equal(accepted, settings.AcceptsClientId(clientId));
    }

    [Fact]
    public void No_additional_clients_means_the_app_client_alone()
    {
        var settings = Settings(additional: null);

        Assert.True(settings.AcceptsClientId("app-client"));
        Assert.False(settings.AcceptsClientId("mcp-claude"));
    }

    [Theory]
    [InlineData(null, new string[0])]
    [InlineData("", new string[0])]
    [InlineData("   ", new string[0])]
    [InlineData("a", new[] { "a" })]
    [InlineData(" a , b ,, ", new[] { "a", "b" })]
    public void The_environment_list_is_comma_separated_and_trimmed(string? raw, string[] expected)
    {
        Assert.Equal(expected, HumbuggSettings.ParseClientIds(raw));
    }

    private static HumbuggSettings Settings(string[]? additional) => new(
        AwsRegion: "us-east-1",
        CognitoRegion: "us-east-1",
        CognitoUserPoolId: "us-east-1_pool",
        CognitoClientId: "app-client",
        CorsOrigins: [],
        AppBaseUrl: "http://localhost:8081",
        DynamoDbEndpointUrl: null,
        ProfilesTable: "p",
        GroupsTable: "g",
        GroupMembersTable: "gm",
        DrawsTable: "d",
        AuditEventsTable: "a",
        AnalyticsEventsTable: "an",
        CognitoAdditionalClientIds: additional);
}
