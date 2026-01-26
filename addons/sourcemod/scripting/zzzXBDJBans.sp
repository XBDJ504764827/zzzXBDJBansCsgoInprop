#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo = 
{
    name = "zzzXBDJBans",
    author = "Antigravity",
    description = "CS:GO Ban System Integration",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDatabase = null;
ConVar g_cvServerId;

public void OnPluginStart()
{
    g_cvServerId = CreateConVar("zzzxbdjbans_server_id", "1", "Server ID for this server instance");
    
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

    char steamId[32];
    char ip[32];
    
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    GetClientIP(client, ip, sizeof(ip));
    
    // 1. Check Bans
    char query[512];
    Format(query, sizeof(query), 
        "SELECT id, reason, duration, expires_at FROM bans WHERE (steam_id = '%s' OR ip = '%s') AND status = 'active' AND (expires_at IS NULL OR expires_at > NOW()) LIMIT 1", 
        steamId, ip);
    
    g_hDatabase.Query(SQL_CheckBanCallback, query, GetClientUserId(client));
    
    // 2. Sync Admin
    Format(query, sizeof(query), "SELECT role FROM admins WHERE steam_id = '%s'", steamId);
    g_hDatabase.Query(SQL_CheckAdminCallback, query, GetClientUserId(client));
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client) || !g_hDatabase)
        return;
        
    char name[MAX_NAME_LENGTH];
    char steamId[32];
    char ip[32];
    char serverName[128] = "Unknown Server";
    char serverIp[64];
    
    GetClientName(client, name, sizeof(name));
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    GetClientIP(client, ip, sizeof(ip));
    
    // Escape name for SQL
    char safeName[MAX_NAME_LENGTH * 2 + 1];
    g_hDatabase.Format(safeName, sizeof(safeName), "%s", name);
    
    // Get server IP/port
    int hostip = FindConVar("hostip").IntValue;
    int hostport = FindConVar("hostport").IntValue;
    Format(serverIp, sizeof(serverIp), "%d.%d.%d.%d:%d", 
        (hostip >> 24) & 0xFF, (hostip >> 16) & 0xFF, (hostip >> 8) & 0xFF, hostip & 0xFF, 
        hostport);

    char query[1024];
    Format(query, sizeof(query), 
        "INSERT INTO player_records (player_name, steam_id, player_ip, server_name, server_address) VALUES ('%s', '%s', '%s', '%s', '%s')",
        safeName, steamId, ip, serverName, serverIp);
        
    g_hDatabase.Query(SQL_LogCallback, query);
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
        
        // Bind the admin to the client
        // Note: RunAdminCacheChecks usually handles this for flatfiles/SQL-admins if configured via admins.cfg/sql
        // Since we are doing custom sync, we manually apply flags or bind identity.
        // Actually, SetUserAdmin works better here.
        
        SetUserAdmin(client, admin, true);
        LogMessage("Granted admin privileges to %N (%s)", client, role);
    }
}

public void SQL_LogCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Logging query failed: %s", error);
    }
}

public Action Timer_CheckBans(Handle timer)
{
    if (!g_hDatabase) return Plugin_Continue;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            OnClientPostAdminCheck(i); // Re-run check
        }
    }
    return Plugin_Continue;
}
