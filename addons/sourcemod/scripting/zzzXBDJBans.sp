#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.1.2"

public Plugin myinfo = 
{
    name = "zzzXBDJBans",
    author = "wwq",
    description = "CS:GO Ban System Integration (Queue Verification)",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDatabase = null;
ConVar g_cvServerId;

public void OnPluginStart()
{
    g_cvServerId = CreateConVar("zzzxbdjbans_server_id", "1", "Server ID for this server instance");
    
    LogMessage("zzzXBDJBans Plugin v%s Loaded. Starting database connection...", PLUGIN_VERSION);
    Database.Connect(OnDatabaseConnected, "zzzXBDJBans");
    
    // Check bans periodically
    CreateTimer(60.0, Timer_CheckBans, _, TIMER_REPEAT);
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to connect to zzzXBDJBans database: %s", error);
        return;
    }
    
    g_hDatabase = db;
    LogMessage("Connected to zzzXBDJBans database successfully.");
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client) || !g_hDatabase)
        return;

    // Start verification process: Insert request into DB
    StartVerification(client);
}

void StartVerification(int client)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        KickClient(client, "Verification Error: Invalid SteamID");
        return;
    }

    // Check if verification is enabled for this server
    char query[256];
    Format(query, sizeof(query), "SELECT verification_enabled FROM servers WHERE id = %d", g_cvServerId.IntValue);
    g_hDatabase.Query(SQL_CheckVerificationEnabledCallback, query, GetClientUserId(client));
}

public void SQL_CheckVerificationEnabledCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    bool enabled = true; // Default to true if error

    if (results == null)
    {
        LogError("Failed to check verification setting: %s", error);
    }
    else if (results.FetchRow())
    {
        enabled = results.FetchInt(0) != 0;
    }

    if (!enabled)
    {
        LogMessage("Verification disabled for this server. Skipping verification for %N.", client);
        CheckBansAndAdmin(client);
        return;
    }

    ContinueVerification(client);
}

int g_VerificationMode[MAXPLAYERS+1]; // 0=None, 1=Manual, 2=Cache

public void OnClientDisconnect(int client)
{
    g_VerificationMode[client] = 0;
}

void ContinueVerification(int client)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    LogMessage("Starting verification for %N (%s). Checking manual list...", client, steamId);

    // 1. Check if user is in MANUAL list (player_verifications)
    char query[256];
    Format(query, sizeof(query), "SELECT status FROM zzzXBDJBans.player_verifications WHERE steam_id = '%s'", steamId);
    g_hDatabase.Query(SQL_CheckManualListCallback, query, GetClientUserId(client));
}

public void SQL_CheckManualListCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results != null && results.FetchRow())
    {
        // Found in manual list!
        g_VerificationMode[client] = 1;
        LogMessage("Player %N found in manual verification list. Polling manual status...", client);
        CreateTimer(1.0, Timer_PollVerification, userid);
    }
    else
    {
        // Not in manual list. Use CACHE.
        g_VerificationMode[client] = 2;
        char steamId[64];
        if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

        LogMessage("Player %N not in manual list. Using Player Cache...", client);

        char query[1024];
        Format(query, sizeof(query), 
            "INSERT INTO zzzXBDJBans.player_cache (steam_id, status) VALUES ('%s', 'pending') ON DUPLICATE KEY UPDATE status='pending', reason=NULL, steam_level=NULL, playtime_minutes=NULL, updated_at=NOW()", 
            steamId);
        
        g_hDatabase.Query(SQL_StartVerificationCallback, query, GetClientUserId(client));
    }
}

public void SQL_StartVerificationCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Failed to insert verification request (Cache): %s", error);
        KickClient(client, "Verification Error: Database Error");
        return;
    }

    // Start checking loop (Single Shot, will recurse if needed)
    CreateTimer(1.0, Timer_PollVerification, userid);
}

public Action Timer_PollVerification(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Stop;

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
        return Plugin_Stop;

    char table[32];
    if (g_VerificationMode[client] == 1) strcopy(table, sizeof(table), "player_verifications");
    else if (g_VerificationMode[client] == 2) strcopy(table, sizeof(table), "player_cache");
    else return Plugin_Stop; // Should not happen

    char query[512];
    Format(query, sizeof(query), "SELECT status, reason FROM zzzXBDJBans.%s WHERE steam_id = '%s'", table, steamId);
    g_hDatabase.Query(SQL_PollVerificationCallback, query, userid);

    return Plugin_Stop;
}

public void SQL_PollVerificationCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null || !results.FetchRow())
    {
        // Failed to read? Retry in 1s
        CreateTimer(1.0, Timer_PollVerification, userid);
        return;
    }

    char status[32];
    char reason[256];
    results.FetchString(0, status, sizeof(status));
    results.FetchString(1, reason, sizeof(reason));

    if (StrEqual(status, "pending"))
    {
        // Still pending? Check again in 1s
        CreateTimer(1.0, Timer_PollVerification, userid);
    }
    else if (StrEqual(status, "allowed"))
    {
        LogMessage("Verification PASSED for %N (%s). Reason: %s", client, (g_VerificationMode[client] == 1) ? "Manual": "Cache", reason);
        CheckBansAndAdmin(client);
    }
    else // denied
    {
        KickClient(client, "Entry Denied: %s", reason);
        LogMessage("Verification DENIED for %N (%s). Reason: %s", client, (g_VerificationMode[client] == 1) ? "Manual": "Cache", reason);
    }
}

// Common logic for checking Bans and Admins
void CheckBansAndAdmin(int client)
{
    char steamId[32];
    char steamIdOther[32];
    char ip[32];
    
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    GetClientIP(client, ip, sizeof(ip));
    
    strcopy(steamIdOther, sizeof(steamIdOther), steamId);
    if (steamId[6] == '0') steamIdOther[6] = '1';
    else if (steamId[6] == '1') steamIdOther[6] = '0';
    
    LogMessage("DEBUG: Checking ban/admin for %N (Steam: %s / %s, IP: %s)", client, steamId, steamIdOther, ip);
    
    // 1. Check Bans
    char query[1024];
    Format(query, sizeof(query), 
        "SELECT id, reason, duration, expires_at FROM bans WHERE (steam_id = '%s' OR steam_id = '%s' OR ip = '%s') AND status = 'active' AND (expires_at IS NULL OR expires_at > NOW()) LIMIT 1", 
        steamId, steamIdOther, ip);
    
    g_hDatabase.Query(SQL_CheckBanCallback, query, GetClientUserId(client));
    
    // 2. Sync Admin
    Format(query, sizeof(query), "SELECT role FROM admins WHERE steam_id = '%s' OR steam_id = '%s'", steamId, steamIdOther);
    g_hDatabase.Query(SQL_CheckAdminCallback, query, GetClientUserId(client));
}

public void SQL_CheckBanCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;
    
    if (results == null)
    {
        LogError("Ban check query failed: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        char reason[128];
        char duration[32];
        results.FetchString(1, reason, sizeof(reason));
        results.FetchString(2, duration, sizeof(duration));
        
        KickClient(client, "You are banned. Reason: %s (Duration: %s)", reason, duration);
        LogMessage("Kicked banned player: %N (%s)", client, reason);
    }
}

public void SQL_CheckAdminCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;
    
    if (results == null)
    {
        LogError("Admin check query failed: %s", error);
        return;
    }
    
    if (results.FetchRow())
    {
        char role[32];
        results.FetchString(0, role, sizeof(role));
        
        AdminId admin = CreateAdmin("TempAdmin");
        if (StrEqual(role, "super_admin"))
        {
            admin.SetFlag(Admin_Root, true);
        }
        else if (StrEqual(role, "admin"))
        {
            admin.SetFlag(Admin_Generic, true);
            admin.SetFlag(Admin_Kick, true);
            admin.SetFlag(Admin_Ban, true);
        }
        
        SetUserAdmin(client, admin, true);
        LogMessage("Granted admin privileges to %N (%s)", client, role);
    }
}

public Action Timer_CheckBans(Handle timer)
{
    if (!g_hDatabase) return Plugin_Continue;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            // Note: We don't want to re-run the FULL delayed check in bans timer loop 
            // because that would spam logs and be inefficient. 
            // Just check bans/admins directly if needed? 
            // For now, let's keep original logic but call the BAN check directly to avoid loop.
            CheckBansAndAdmin(i);
        }
    }
    return Plugin_Continue;
}
