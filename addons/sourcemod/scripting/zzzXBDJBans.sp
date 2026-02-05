#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.3.0"

// 验证标准配置
#define REQUIRED_RATING 3.0
#define REQUIRED_LEVEL 1

public Plugin myinfo = 
{
    name = "zzzXBDJBans",
    author = "wwq",
    description = "CS:GO Ban System Integration (Local Verification)",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDatabase = null;
ConVar g_cvServerId;

// 玩家验证模式: 0=None, 1=Manual, 2=Cache
int g_VerificationMode[MAXPLAYERS+1];

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
    g_hDatabase.SetCharset("utf8mb4");
    LogMessage("Connected to zzzXBDJBans database successfully.");
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client) || !g_hDatabase)
        return;

    StartVerification(client);
}

public void OnClientDisconnect(int client)
{
    g_VerificationMode[client] = 0;
}

// ============================================
// 验证流程入口
// ============================================

void StartVerification(int client)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        KickClient(client, "验证错误：无效的SteamID");
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

    bool enabled = true;

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
        // Found in manual list
        g_VerificationMode[client] = 1;
        LogMessage("Player %N found in manual verification list.", client);
        QueryCacheData(client, "player_verifications");
    }
    else
    {
        // Not in manual list, use cache
        g_VerificationMode[client] = 2;
        char steamId[64];
        if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

        LogMessage("Player %N not in manual list. Checking Player Cache...", client);
        QueryCacheData(client, "player_cache");
    }
}

// ============================================
// 查询缓存数据
// ============================================

void QueryCacheData(int client, const char[] table)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    char query[512];
    Format(query, sizeof(query), 
        "SELECT status, steam_level, gokz_rating FROM zzzXBDJBans.%s WHERE steam_id = '%s'", 
        table, steamId);
    
    // Pack table name with userid
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(table);
    
    g_hDatabase.Query(SQL_QueryCacheDataCallback, query, pack);
}

public void SQL_QueryCacheDataCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    char table[32];
    pack.ReadString(table, sizeof(table));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    char steamId[64];
    char playerName[128];
    char ip[32];
    
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;
    GetClientName(client, playerName, sizeof(playerName));
    GetClientIP(client, ip, sizeof(ip));

    // 检查查询错误
    if (results == null)
    {
        LogError("Cache query failed: %s", error);
        KickClient(client, "验证错误：数据库查询失败");
        return;
    }

    if (results.FetchRow())
    {
        char status[32];
        results.FetchString(0, status, sizeof(status));
        
        // 获取 level (可能为 NULL)
        int level = 0;
        if (!results.IsFieldNull(1))
        {
            level = results.FetchInt(1);
        }
        
        // 获取 rating (可能为 NULL)
        float rating = 0.0;
        if (!results.IsFieldNull(2))
        {
            char ratingStr[32];
            results.FetchString(2, ratingStr, sizeof(ratingStr));
            rating = StringToFloat(ratingStr);
        }

        LogMessage("Player %N cache status: %s, Level=%d, Rating=%.2f", client, status, level, rating);

        if (StrEqual(status, "allowed"))
        {
            // Previously verified and allowed - direct pass
            LogMessage("Player %N has ALLOWED status. Direct pass.", client);
            CheckBansAndAdmin(client);
            return;
        }
        else if (StrEqual(status, "verified"))
        {
            // Data available from backend, perform local verification
            LogMessage("Player %N has valid data. Checking whitelist...", client);
            CheckWhitelist(client, level, rating);
            return;
        }
        else if (StrEqual(status, "pending"))
        {
            // Still pending, wait for backend
            LogMessage("Player %N data still pending. Waiting 2s...", client);
            CreateTimer(2.0, Timer_WaitForData, userid);
            return;
        }
        else if (StrEqual(status, "denied"))
        {
            // Previously denied - re-verify (maybe player improved their rating/level)
            LogMessage("Player %N was previously denied. Re-verifying...", client);
        }
        else
        {
            // Unknown status
            LogMessage("Player %N has unknown status '%s'. Re-verifying...", client, status);
        }
    }
    else
    {
        // No cache record exists, create one
        LogMessage("Player %N not found in cache. Creating pending record...", client);
    }
    
    char escapedName[256];
    g_hDatabase.Escape(playerName, escapedName, sizeof(escapedName));
    
    char query[1024];
    Format(query, sizeof(query), 
        "INSERT INTO zzzXBDJBans.player_cache (steam_id, player_name, ip_address, status) VALUES ('%s', '%s', '%s', 'pending') ON DUPLICATE KEY UPDATE player_name='%s', ip_address='%s', status='pending', updated_at=NOW()", 
        steamId, escapedName, ip, escapedName, ip);
    
    g_hDatabase.Query(SQL_InsertPendingCallback, query, GetClientUserId(client));
}

public void SQL_InsertPendingCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Failed to insert pending record: %s", error);
        KickClient(client, "验证错误：数据库错误");
        return;
    }

    // Wait for backend to fetch data
    CreateTimer(1.0, Timer_WaitForData, userid);
}

public Action Timer_WaitForData(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Stop;

    char table[32];
    if (g_VerificationMode[client] == 1) 
        strcopy(table, sizeof(table), "player_verifications");
    else 
        strcopy(table, sizeof(table), "player_cache");

    QueryCacheData(client, table);
    return Plugin_Stop;
}

// ============================================
// 白名单检查
// ============================================

void CheckWhitelist(int client, int level, float rating)
{
    char steamId[64];
    char steamId2[64];
    
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    GetClientAuthId(client, AuthId_Steam2, steamId2, sizeof(steamId2));
    
    // Pack data for callback
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(level);
    pack.WriteFloat(rating);
    
    char query[512];
    Format(query, sizeof(query), 
        "SELECT COUNT(*) FROM zzzXBDJBans.whitelist WHERE steam_id = '%s' OR steam_id = '%s'",
        steamId, steamId2);
    
    g_hDatabase.Query(SQL_CheckWhitelistCallback, query, pack);
}

public void SQL_CheckWhitelistCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int level = pack.ReadCell();
    float rating = pack.ReadFloat();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    bool inWhitelist = false;
    if (results != null && results.FetchRow())
    {
        inWhitelist = results.FetchInt(0) > 0;
    }

    // Perform local verification
    PerformLocalVerification(client, level, rating, inWhitelist);
}

// ============================================
// 本地验证判断（核心逻辑）
// ============================================

void PerformLocalVerification(int client, int level, float rating, bool inWhitelist)
{
    char steamId[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));

    // Check verification criteria
    bool passed = false;
    char reason[256];

    if (rating >= REQUIRED_RATING && level >= REQUIRED_LEVEL)
    {
        passed = true;
        Format(reason, sizeof(reason), "验证通过：Rating %.2f / 等级 %d", rating, level);
    }
    else if (inWhitelist)
    {
        passed = true;
        Format(reason, sizeof(reason), "白名单通过");
    }
    else
    {
        Format(reason, sizeof(reason), "验证失败：Rating %.2f(需>=%.1f) / 等级 %d(需>=%d)，不在白名单中", 
            rating, REQUIRED_RATING, level, REQUIRED_LEVEL);
    }

    if (passed)
    {
        LogMessage("Verification PASSED for %N: %s", client, reason);
        
        // Update cache status to allowed
        UpdateCacheStatus(steamId, "allowed", reason);
        
        // Continue to check bans and admin
        CheckBansAndAdmin(client);
    }
    else
    {
        LogMessage("Verification DENIED for %N: %s", client, reason);
        
        // Update cache status to denied
        UpdateCacheStatus(steamId, "denied", reason);
        
        // Kick with Chinese message
        KickClient(client, "%s", reason);
    }
}

void UpdateCacheStatus(const char[] steamId, const char[] status, const char[] reason)
{
    char escapedReason[512];
    g_hDatabase.Escape(reason, escapedReason, sizeof(escapedReason));
    
    char query[1024];
    Format(query, sizeof(query), 
        "UPDATE zzzXBDJBans.player_cache SET status = '%s', reason = '%s', updated_at = NOW() WHERE steam_id = '%s'",
        status, escapedReason, steamId);
    
    g_hDatabase.Query(SQL_UpdateStatusCallback, query);
}

public void SQL_UpdateStatusCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to update cache status: %s", error);
    }
}

// ============================================
// 封禁和管理员检查
// ============================================

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
        
        KickClient(client, "您已被封禁。原因：%s（时长：%s）", reason, duration);
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

// ============================================
// 定时检查封禁
// ============================================

public Action Timer_CheckBans(Handle timer)
{
    if (!g_hDatabase) return Plugin_Continue;
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            CheckBansAndAdmin(i);
        }
    }
    return Plugin_Continue;
}
