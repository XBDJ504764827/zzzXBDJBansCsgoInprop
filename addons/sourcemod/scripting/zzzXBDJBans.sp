#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.4.3"

// 验证标准配置
#define REQUIRED_RATING 3.0
#define REQUIRED_LEVEL 1

public Plugin myinfo = 
{
    name = "zzzXBDJBans",
    author = "wwq",
    description = "CS:GO Ban System Integration",
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

    // 检查服务器是否启用验证
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
        LogMessage("Verification disabled for this server. Skipping for %N.", client);
        CheckBansAndAdmin(client);
        return;
    }

    // Step 1: 首先检查白名单
    CheckWhitelist(client);
}

// ============================================
// Step 1: 白名单检查（最优先）
// ============================================

void CheckWhitelist(int client)
{
    char steamId[64];
    char steamId2[64];
    
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    GetClientAuthId(client, AuthId_Steam2, steamId2, sizeof(steamId2));
    
    char query[512];
    Format(query, sizeof(query), 
        "SELECT status FROM zzzXBDJBans.whitelist WHERE steam_id_64 = '%s' OR steam_id = '%s' OR steam_id = '%s'",
        steamId, steamId, steamId2);
    
    g_hDatabase.Query(SQL_CheckWhitelistCallback, query, GetClientUserId(client));
}

public void SQL_CheckWhitelistCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Whitelist check failed: %s", error);
        KickClient(client, "验证错误：数据库查询失败");
        return;
    }

    if (results.FetchRow())
    {
        char status[32];
        results.FetchString(0, status, sizeof(status));

        if (StrEqual(status, "rejected"))
        {
            KickClient(client, "您已被拒绝访问本服务器");
            LogMessage("Player %N blocked (whitelist rejected).", client);
            return;
        }

        if (StrEqual(status, "approved"))
        {
            // 在白名单中，直接放行
            LogMessage("Player %N is in WHITELIST. Direct pass.", client);
            CheckBansAndAdmin(client);
            return;
        }
        
        // pending 状态，继续往下走，看是否满足自动验证
    }


    // 不在白名单，进入 Step 2: 检查缓存
    LogMessage("Player %N not in whitelist. Checking cache...", client);
    CheckCache(client);
}

// ============================================
// Step 2: 缓存检查
// ============================================

void CheckCache(int client)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    char query[512];
    Format(query, sizeof(query), 
        "SELECT status FROM zzzXBDJBans.player_cache WHERE steam_id = '%s' AND status = 'allowed'", 
        steamId);
    
    g_hDatabase.Query(SQL_CheckCacheCallback, query, GetClientUserId(client));
}

public void SQL_CheckCacheCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Cache check failed: %s", error);
        KickClient(client, "验证错误：数据库查询失败");
        return;
    }

    if (results.FetchRow())
    {
        // 缓存中有 allowed 状态，直接放行
        LogMessage("Player %N found in cache with ALLOWED status. Direct pass.", client);
        CheckBansAndAdmin(client);
        return;
    }

    // 缓存中没有或不是 allowed，进入 Step 3: 创建验证请求
    LogMessage("Player %N not in cache. Creating verification request...", client);
    CreateVerificationRequest(client);
}

// ============================================
// Step 3: 创建验证请求，等待后端获取数据
// ============================================

void CreateVerificationRequest(int client)
{
    char steamId[64];
    char playerName[128];
    char ip[32];
    
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;
    GetClientName(client, playerName, sizeof(playerName));
    GetClientIP(client, ip, sizeof(ip));
    
    char escapedName[256];
    g_hDatabase.Escape(playerName, escapedName, sizeof(escapedName));
    
    char query[1024];
    Format(query, sizeof(query), 
        "INSERT INTO zzzXBDJBans.player_cache (steam_id, player_name, ip_address, status) VALUES ('%s', '%s', '%s', 'pending') ON DUPLICATE KEY UPDATE player_name='%s', ip_address='%s', status='pending', steam_level=NULL, gokz_rating=NULL, updated_at=NOW()", 
        steamId, escapedName, ip, escapedName, ip);
    
    g_hDatabase.Query(SQL_CreateRequestCallback, query, GetClientUserId(client));
}

public void SQL_CreateRequestCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Failed to create verification request: %s", error);
        KickClient(client, "验证错误：数据库错误");
        return;
    }

    // 等待后端获取数据
    CreateTimer(1.5, Timer_PollVerification, userid);
}

public Action Timer_PollVerification(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Stop;

    PollVerificationResult(client);
    return Plugin_Stop;
}

void PollVerificationResult(int client)
{
    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    char query[512];
    Format(query, sizeof(query), 
        "SELECT status, steam_level, gokz_rating FROM zzzXBDJBans.player_cache WHERE steam_id = '%s'", 
        steamId);
    
    g_hDatabase.Query(SQL_PollVerificationCallback, query, GetClientUserId(client));
}

public void SQL_PollVerificationCallback(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;

    if (results == null)
    {
        LogError("Poll verification failed: %s", error);
        KickClient(client, "验证错误：数据库查询失败");
        return;
    }

    if (!results.FetchRow())
    {
        LogError("Verification record not found for player %N", client);
        KickClient(client, "验证错误：记录不存在");
        return;
    }

    char status[32];
    results.FetchString(0, status, sizeof(status));
    
    if (StrEqual(status, "pending"))
    {
        // 后端还未处理，继续等待
        LogMessage("Player %N data still pending. Waiting...", client);
        CreateTimer(1.5, Timer_PollVerification, userid);
        return;
    }
    
    // 后端已获取数据 (status = 'verified')
    int level = 0;
    float rating = 0.0;
    
    if (!results.IsFieldNull(1))
    {
        level = results.FetchInt(1);
    }
    if (!results.IsFieldNull(2))
    {
        char ratingStr[32];
        results.FetchString(2, ratingStr, sizeof(ratingStr));
        rating = StringToFloat(ratingStr);
    }

    LogMessage("Player %N data received: Level=%d, Rating=%.2f", client, level, rating);
    
    // Step 4: 执行本地验证
    PerformVerification(client, level, rating);
}

// ============================================
// Step 4: 执行验证判断
// ============================================

void PerformVerification(int client, int level, float rating)
{
    char steamId[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));

    bool passed = (rating >= REQUIRED_RATING && level >= REQUIRED_LEVEL);
    char reason[256];

    if (passed)
    {
        Format(reason, sizeof(reason), "验证通过：Rating %.2f / 等级 %d", rating, level);
        LogMessage("Verification PASSED for %N: %s", client, reason);
        
        // 缓存通过的玩家
        UpdateCacheStatus(steamId, "allowed", reason);
        
        CheckBansAndAdmin(client);
    }
    else
    {
        Format(reason, sizeof(reason), "验证失败：Rating %.2f(需>=%.1f) / 等级 %d(需>=%d)", 
            rating, REQUIRED_RATING, level, REQUIRED_LEVEL);
        LogMessage("Verification DENIED for %N: %s", client, reason);
        
        // 删除缓存，不保存失败记录
        DeleteFromCache(steamId);
        
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
    
    g_hDatabase.Query(SQL_GenericCallback, query);
}

void DeleteFromCache(const char[] steamId)
{
    char query[256];
    Format(query, sizeof(query), 
        "DELETE FROM zzzXBDJBans.player_cache WHERE steam_id = '%s'",
        steamId);
    
    g_hDatabase.Query(SQL_GenericCallback, query);
}

public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("SQL query failed: %s", error);
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
    char steamId64[64];
    
    GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    GetClientIP(client, ip, sizeof(ip));
    
    LogMessage("Checking bans for %N (SteamID: %s, IP: %s)", client, steamId64, ip);

    strcopy(steamIdOther, sizeof(steamIdOther), steamId);
    if (steamId[6] == '0') steamIdOther[6] = '1';
    else if (steamId[6] == '1') steamIdOther[6] = '0';
    
    // 1. Check Bans
    // Fetch ban_type (5) and steam_id_64 (6) from DB
    char query[1024];
    Format(query, sizeof(query), 
        "SELECT id, reason, duration, expires_at, ip, ban_type, steam_id_64 FROM bans WHERE (steam_id_64 = '%s' OR steam_id = '%s' OR steam_id = '%s' OR ip = '%s') AND status = 'active' AND (expires_at IS NULL OR expires_at > NOW()) ORDER BY id DESC LIMIT 1", 
        steamId64, steamId, steamIdOther, ip);
    
    g_hDatabase.Query(SQL_CheckBanCallback, query, GetClientUserId(client));
    
    // 2. Sync Admin (Disabled per requirement: Web admins do not get in-game privileges)
    // Format(query, sizeof(query), "SELECT role FROM admins WHERE steam_id_64 = '%s' OR steam_id = '%s' OR steam_id = '%s'", steamId64, steamId, steamIdOther);
    // g_hDatabase.Query(SQL_CheckAdminCallback, query, GetClientUserId(client));
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
        int banId = results.FetchInt(0);
        char reason[128];
        char duration[32];
        char storedIp[32];
        char banType[32];
        char bannedSteamId64[64];
        
        results.FetchString(1, reason, sizeof(reason));
        results.FetchString(2, duration, sizeof(duration));
        results.FetchString(4, storedIp, sizeof(storedIp));
        results.FetchString(5, banType, sizeof(banType));
        results.FetchString(6, bannedSteamId64, sizeof(bannedSteamId64));
        
        char clientSteamId64[64];
        char clientIp[32];
        GetClientAuthId(client, AuthId_SteamID64, clientSteamId64, sizeof(clientSteamId64));
        GetClientIP(client, clientIp, sizeof(clientIp));

        // 判断是否是本人 (SteamID 匹配)
        bool isSameAccount = StrEqual(clientSteamId64, bannedSteamId64);

        if (isSameAccount)
        {
            // Case A: 同账号匹配 (Direct Ban)
            // 如果数据库中没有 IP 记录，更新为当前玩家 IP
            if (storedIp[0] == '\0')
            {
                char updateQuery[256];
                Format(updateQuery, sizeof(updateQuery), "UPDATE bans SET ip = '%s' WHERE id = %d", clientIp, banId);
                g_hDatabase.Query(SQL_GenericCallback, updateQuery);
                LogMessage("Updated missing IP for banned player %N (BanID: %d, IP: %s)", client, banId, clientIp);
            }
            // 踢出
            KickClient(client, "您已被封禁。原因：%s（时长：%s）", reason, duration);
            LogMessage("Kicked banned player: %N (Account Match, BanID: %d)", client, banId);
        }
        else
        {
            // Case B: 异账号匹配 (IP Match)
            if (StrEqual(banType, "ip"))
            {
                // 是 IP 封禁 -> 连坐
                LogMessage("IP Ban Match for %N! (Linked to BanID: %d, IP: %s)", client, banId, clientIp);

                // 为当前马甲号创建新封禁
                char newReason[256];
                Format(newReason, sizeof(newReason), "同IP关联封禁 (Linked to %s)", bannedSteamId64);
                
                char insertQuery[1024];
                Format(insertQuery, sizeof(insertQuery), 
                    "INSERT INTO bans (name, steam_id, steam_id_64, ip, ban_type, reason, duration, admin_name, expires_at, created_at, status, server_id) SELECT '%N', 'PENDING', '%s', '%s', 'account', '%s', duration, 'System (IP Linked)', expires_at, NOW(), 'active', server_id FROM bans WHERE id = %d",
                    client, clientSteamId64, clientIp, newReason, banId);
                
                g_hDatabase.Query(SQL_GenericCallback, insertQuery);

                KickClient(client, "检测到关联封禁 IP。在此 IP 上的所有账号均被禁止进入。");
            }
            else
            {
                // 不是 IP 封禁 -> 放行
                LogMessage("Player %N shares IP with banned player (BanID: %d) but BanType is '%s'. ALLOWING access.", client, banId, banType);
                // 不执行 KickClient，直接返回
            }
        }
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
