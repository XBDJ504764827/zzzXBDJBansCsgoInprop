#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <steamworks> // 需要安装 SteamWorks 扩展
#include <basecomm>

/**
 * 插件信息
 */
public Plugin myinfo = 
{
    name = "zzzXBDJBans Integration",
    author = "Antigravity",
    description = "Sync bans and records with zzzXBDJBans API",
    version = "1.0.0",
    url = "http://your-site.com"
};

// --- ConVars ---
ConVar g_cvHost;
ConVar g_cvUser;
ConVar g_cvPass;
ConVar g_cvServerName;

char g_szHost[256];
char g_szUser[64];
char g_szPass[64];
char g_szServerName[128];
char g_szToken[2048]; // JWT Token can be long
bool g_bAuthenticated = false;

// --- Timers ---
Handle g_hRetryTimer = null;

public void OnPluginStart()
{
    // 初始化 ConVars
    g_cvHost = CreateConVar("sm_xb_host", "http://localhost:3000/api", "Backend API URL (no trailing slash)");
    g_cvUser = CreateConVar("sm_xb_user", "admin", "API Username for Bot");
    g_cvPass = CreateConVar("sm_xb_pass", "123", "API Password for Bot");
    g_cvServerName = CreateConVar("sm_xb_server_name", "CSGO Server", "Server Name for Records");
    
    AutoExecConfig(true, "zzzXBDJBans");
    
    // 加载配置
    GetConVarValues();
    HookConVarChange(g_cvHost, OnConVarChanged);
    HookConVarChange(g_cvUser, OnConVarChanged);
    HookConVarChange(g_cvPass, OnConVarChanged);
    HookConVarChange(g_cvServerName, OnConVarChanged);

    // 定时检查所有在线玩家 (每60秒)
    CreateTimer(60.0, Timer_CheckAllPlayers, _, TIMER_REPEAT);

    // 尝试登录
    DoLogin();
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetConVarValues();
    g_bAuthenticated = false;
    DoLogin();
}

void GetConVarValues()
{
    g_cvHost.GetString(g_szHost, sizeof(g_szHost));
    g_cvUser.GetString(g_szUser, sizeof(g_szUser));
    g_cvPass.GetString(g_szPass, sizeof(g_szPass));
    g_cvServerName.GetString(g_szServerName, sizeof(g_szServerName));
    
    // Remove trailing slash if user added it
    int len = strlen(g_szHost);
    if (len > 0 && g_szHost[len-1] == '/')
        g_szHost[len-1] = '\0';
}

// ----------------------------------------------------------------------------
// Authentication
// ----------------------------------------------------------------------------
void DoLogin()
{
    if (g_bAuthenticated) return;

    char url[512];
    Format(url, sizeof(url), "%s/auth/login", g_szHost);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
    
    JSONObject json = new JSONObject();
    json.SetString("username", g_szUser);
    json.SetString("password", g_szPass);
    
    char body[512];
    json.ToString(body, sizeof(body));
    delete json;
    
    SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", body, strlen(body));
    SteamWorks_SetHTTPRequestContextValue(request, 0);
    SteamWorks_SetHTTPCallbacks(request, OnLoginComplete);
    SteamWorks_SendHTTPRequest(request);
}

public int OnLoginComplete(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if (!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
    {
        LogError("[XBDJ] Login failed. Status: %d", eStatusCode);
        // Retry later
        if (g_hRetryTimer == null)
            g_hRetryTimer = CreateTimer(30.0, Timer_RetryLogin);
        
        delete request;
        return;
    }

    int bodySize;
    if (SteamWorks_GetHTTPResponseBodySize(request, bodySize))
    {
        char[] response = new char[bodySize + 1];
        SteamWorks_GetHTTPResponseBodyData(request, response, bodySize);
        
        // Parse JSON to get token
        // Use custom parser or simple extraction if SMJansson not avail.
        // Assuming user has a cleaner JSON parser, but using simple str search for portability here 
        // OR expecting SMJansson. Since user didn't specify utils, I'll try basic string parsing for the token field 
        // to minimize dependencies, or rely on simple JSON structure.
        
        // Example response: {"token":"..."}
        // Let's implement a very distinct "token":" finder
        
        int start = StrContains(response, "\"token\":");
        if (start != -1)
        {
            start += 8; // skip "token":
            // Find quote start
            while (response[start] != '\"' && response[start] != '\0') start++;
            if (response[start] == '\"')
            {
                start++; // skip quote
                int end = start;
                while (response[end] != '\"' && response[end] != '\0') end++;
                
                if (end > start)
                {
                    strcopy(g_szToken, end - start + 1, response[start]);
                    g_bAuthenticated = true;
                    LogMessage("[XBDJ] Authenticated successfully.");
                    
                    // Kill retry timer if exists
                    if (g_hRetryTimer != null)
                    {
                        KillTimer(g_hRetryTimer);
                        g_hRetryTimer = null;
                    }
                    
                    // Check everyone now that we are auth
                    CheckAllOnlinePlayers();
                }
            }
        }
    }
    
    delete request;
}

public Action Timer_RetryLogin(Handle timer)
{
    g_hRetryTimer = null;
    DoLogin();
    return Plugin_Stop;
}

// ----------------------------------------------------------------------------
// Check Ban Logic
// ----------------------------------------------------------------------------

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client)) return;
    CheckBan(client);
    UploadRecord(client);
}

void CheckBan(int client)
{
    if (!g_bAuthenticated) return;

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return;
    
    char ip[64];
    GetClientIP(client, ip, sizeof(ip));

    char url[512];
    // Encode params? Basic SteamID/IP shouldn't need heavy encoding but better safe.
    // Assuming simple format.
    Format(url, sizeof(url), "%s/check_ban?steam_id=%s&ip=%s", g_szHost, steamId, ip);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    SteamWorks_SetHTTPRequestHeaderValue(request, "Authorization", g_szToken);
    SteamWorks_SetHTTPRequestContextValue(request, GetClientUserId(client));
    SteamWorks_SetHTTPCallbacks(request, OnCheckBanComplete);
    SteamWorks_SendHTTPRequest(request);
}

public int OnCheckBanComplete(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    int userid = SteamWorks_GetHTTPRequestContextValue(request);
    int client = GetClientOfUserId(userid);

    if (bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK)
    {
        // 200 OK means BANNED (per API design)
        
        // Safety: Client might have disconnected
        if (client > 0 && IsClientConnected(client))
        {
            // Parse reason and duration from JSON body
            int bodySize;
            SteamWorks_GetHTTPResponseBodySize(request, bodySize);
            char[] body = new char[bodySize + 1];
            SteamWorks_GetHTTPResponseBodyData(request, body, bodySize);
            
            // Simple Parse: "reason":"..."
            char reason[128];
            strcopy(reason, sizeof(reason), "Banned by Admin"); // Default
            
            int rStart = StrContains(body, "\"reason\":\"");
             if (rStart != -1)
            {
                rStart += 10;
                int rEnd = rStart;
                while (body[rEnd] != '\"' && body[rEnd] != '\0') rEnd++;
                if (rEnd > rStart)
                {
                    int len = rEnd - rStart;
                    if (len >= sizeof(reason)) len = sizeof(reason) - 1;
                    strcopy(reason, len + 1, body[rStart]);
                }
            }
            
            KickClient(client, "You are BANNED: %s", reason);
            LogMessage("Kicked banned player %N (Reason: %s)", client, reason);
        }
    }
    else if (eStatusCode == k_EHTTPStatusCode401Unauthorized)
    {
        // Token expired?
        g_bAuthenticated = false;
        DoLogin();
    }
    // 404 means Not Banned, ignore.

    delete request;
}

// Periodic Check
public Action Timer_CheckAllPlayers(Handle timer)
{
    CheckAllOnlinePlayers();
    return Plugin_Continue;
}

void CheckAllOnlinePlayers()
{
    if (!g_bAuthenticated) return;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            CheckBan(i);
        }
    }
}

// ----------------------------------------------------------------------------
// Upload Player Record
// ----------------------------------------------------------------------------
void UploadRecord(int client)
{
    if (!g_bAuthenticated) return;
     
    char name[128];
    GetClientName(client, name, sizeof(name));
    
    char steamId[64];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    
    char ip[64];
    GetClientIP(client, ip, sizeof(ip));
    
    // Server IP? We can get it or just send port.
    // For simplicity sending convar.
    
    char url[512];
    Format(url, sizeof(url), "%s/records", g_szHost);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
    SteamWorks_SetHTTPRequestHeaderValue(request, "Authorization", g_szToken);

    // Manual JSON construction
    // Avoid special chars breaking it - in prod use SMJansson. 
    // Escaping quotes minimal check:
    ReplaceString(name, sizeof(name), "\"", "\\\"");
    ReplaceString(g_szServerName, sizeof(g_szServerName), "\"", "\\\"");

    // Get Server IP
    int ips[4];
    int port;
    int ipint = GetConVarInt(FindConVar("hostip"));
    port = GetConVarInt(FindConVar("hostport"));
    ips[0] = (ipint >> 24) & 0x000000FF;
    ips[1] = (ipint >> 16) & 0x000000FF;
    ips[2] = (ipint >> 8) & 0x000000FF;
    ips[3] = ipint & 0x000000FF;
    char serverAddr[64];
    Format(serverAddr, sizeof(serverAddr), "%d.%d.%d.%d:%d", ips[0], ips[1], ips[2], ips[3], port);

    char body[1024];
    Format(body, sizeof(body), 
        "{\"player_name\":\"%s\",\"steam_id\":\"%s\",\"player_ip\":\"%s\",\"server_name\":\"%s\",\"server_address\":\"%s\"}",
        name, steamId, ip, g_szServerName, serverAddr);

    SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", body, strlen(body));
    SteamWorks_SendHTTPRequest(request);
}

// ----------------------------------------------------------------------------
// Ban Command Hook (Server -> Web)
// ----------------------------------------------------------------------------
public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any source)
{
    // Block SourceMod's local ban and send to API instead
    // source is the admin index (0 for server)
    
    // We only care if we are authenticated. If not, fallback to local ban?
    // User requested: "Server banned player uploaded to website".
    // Better to block local and force web.
    
    if (!g_bAuthenticated)
    {
        PrintToConsole(source, "[XBDJ] Error: Not connected to Ban API. Local ban used.");
        return Plugin_Continue; // Allow local ban if API down
    }
    
    char targetName[128];
    GetClientName(client, targetName, sizeof(targetName));
    ReplaceString(targetName, sizeof(targetName), "\"", "\\\"");

    char targetSteam[64];
    GetClientAuthId(client, AuthId_Steam2, targetSteam, sizeof(targetSteam));
    
    char targetIP[64];
    GetClientIP(client, targetIP, sizeof(targetIP));
    
    char adminName[64];
    if (source > 0 && source <= MaxClients)
        GetClientName(source, adminName, sizeof(adminName));
    else
        strcopy(adminName, sizeof(adminName), "Console/Server");
        
    // Duration: SM uses 0 for perm. API uses string ("0" or "permanent"?)
    // Converting mintues to string format your API expects. 
    // API `parse_duration` handles: "30m", "1h", "permanent", or raw seconds/minutes?
    // Let's check API `utils::parse_duration`. 
    // It accepts "1d", "30m". 
    // SM `time` is in minutes.
    
    char durationStr[32];
    if (time == 0)
        strcopy(durationStr, sizeof(durationStr), "permanent");
    else
        Format(durationStr, sizeof(durationStr), "%dm", time);
        
    // Build JSON
    // Request: name, steam_id, ip, ban_type, reason, duration, admin_name
    char body[2048];
    // Simple JSON construction
    Format(body, sizeof(body), 
        "{\"name\":\"%s\",\"steam_id\":\"%s\",\"ip\":\"%s\",\"ban_type\":\"account\",\"reason\":\"%s\",\"duration\":\"%s\",\"admin_name\":\"%s\"}",
        targetName, targetSteam, targetIP, reason, durationStr, adminName);
        
    // Send Request
    SendBanRequest(body);
    
    // Kick immediate
    KickClient(client, "Banned: %s", reason);

    return Plugin_Handled; // Prevent SM from writing to banned_user.cfg or local DB
}

void SendBanRequest(const char[] body)
{
    char url[512];
    Format(url, sizeof(url), "%s/bans", g_szHost);
    
    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
    SteamWorks_SetHTTPRequestHeaderValue(request, "Authorization", g_szToken);
    SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", body, strlen(body));
    SteamWorks_SetHTTPCallbacks(request, OnBanRequestComplete);
    SteamWorks_SendHTTPRequest(request);
}

public int OnBanRequestComplete(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
    if (bRequestSuccessful && (eStatusCode == k_EHTTPStatusCode201Created || eStatusCode == k_EHTTPStatusCode200OK))
    {
        LogMessage("[XBDJ] Ban uploaded successfully.");
    }
    else
    {
        LogError("[XBDJ] Ban upload failed. Status: %d", eStatusCode);
    }
    delete request;
}
