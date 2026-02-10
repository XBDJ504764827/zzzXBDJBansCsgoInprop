# zzzXBDJBans CSGO Plugin (SourceMod)

![SourceMod](https://img.shields.io/badge/SourceMod-1.11%2B-black?style=for-the-badge&logo=counterstrike&logoColor=white)
![CS:GO](https://img.shields.io/badge/CS:GO-Legacy-F7931E?style=for-the-badge&logo=steam&logoColor=white)

zzzXBDJBans 的 CSGO 服务器端插件，基于 SourceMod 开发。作为连接游戏服务器与后端 API 的桥梁，负责实时验证玩家身份、同步管理员权限以及执行封禁操作。

## ✨ 功能特性

- 🔒 **进服验证**：玩家连接时自动检查 SteamID、IP 和 Steam 等级/Rating。
- 🚫 **封禁同步**：从后端数据库实时同步封禁信息，并在玩家违规时自动踢出。
- 👮 **管理员同步**：自动授予后端配置的管理员权限（Flag）。
- 📝 **白名单检查**：优先允许白名单内的玩家进入，支持自动放行与人工审核模式。
- 💾 **本地缓存**：数据库连接失败时使用本地缓存（sqlite/flatfile）或内存缓存以保证服务可用性。

## 🛠️ 依赖插件

本插件依赖以下 SourceMod 扩展/插件：

1. **SourceMod** (>= 1.11)
2. **MetaMod:Source** (>= 1.11)
3. **SteamWorks** (用于 HTTP 请求，或者使用内置的 Database 模块连接 MySQL)
   - *注意：本项目目前主要使用 Database 模块直接连接 MySQL/MariaDB。*

## 📦 安装步骤

### 1. 准备文件

编译生成的插件文件位于 `addons/sourcemod/scripting/compiled/zzzXBDJBans.smx`。

### 2. 上传文件

将 `zzzXBDJBans.smx` 上传到服务器的 `csgo/addons/sourcemod/plugins/` 目录。

### 3. 配置数据库连接

编辑服务器上的 `csgo/addons/sourcemod/configs/databases.cfg` 文件，添加 `zzzXBDJBans` 数据库配置：

```cfg
"zzzXBDJBans"
{
    "driver"    "mysql"
    "host"      "your_mysql_host"
    "database"  "zzzXBDJBans"
    "user"      "your_db_user"
    "pass"      "your_db_password"
    //"port"    "3306"
}
```

### 4. 加载插件

在服务器控制台执行：

```bash
sm plugins load zzzXBDJBans
```
或者重启服务器。

## ⚙️ 配置说明 (CVARs)

插件会自动创建配置文件 `cfg/sourcemod/zzzXBDJBans.cfg`（首次运行后）。

| CVAR | 默认值 | 描述 |
| :--- | :--- | :--- |
| `zzzxbdjbans_server_id` | `1` | 服务器 ID (对应后端数据库中 `servers` 表的 ID) |
| `zzzxbdjbans_check_interval` | `60.0` | 定时检查封禁状态的间隔 (秒) |

## 🔨 编译指南

如果您需要修改插件源码，请按以下步骤编译：

1. 确保已安装 SourceMod 编译器 (`spcomp`)。
2. 进入 `scripting` 目录。
3. 运行编译脚本：

   **Linux/Mac**:
   ```bash
   chmod +x compile.sh
   ./compile.sh zzzXBDJBans.sp
   ```

   **Windows**:
   将 `zzzXBDJBans.sp` 拖拽到 `spcomp.exe` 上。

## 🤝 贡献

欢迎提交 Pull Request 或 Issue 来改进本项目。

## 📄 许可证

[MIT License](LICENSE)
