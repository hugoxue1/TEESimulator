# TEESimulator canary-76 定制 APatch 适配说明（ckb-port-apatch）

> 前置阅读：旧分支 `ckb-apatch-v4.0` 的 `docs/APatch_定制适配说明_2026-08-21.md`
>（根因、bounded privileged-exec 方案、live-policy 计数痕迹、踩坑清单仍然有效，本文只记录
> canary-76 移植差异）。基线 = 官方 canary-76（分支 `ckb-canary-76`），移植补丁 =
> `ckb_patches/0032`（总集）、`0045`（domainless 保持）、`0047`（exact injection 核心）。

## canary-76 与 v4.0 的架构差异（影响适配点）

1. **Injector.kt**：canary-76 重构了注入循环——新增 `lastPid` 存活快查（`isNamedProcess`）避免
   每轮全量扫 /proc，日志前缀统一为首字母大写的 `Injector:`。APatch exact 注入逻辑按新结构重排，
   不再照搬旧 hunk。
2. **injector/main.cpp**：canary-76 统一了日志前缀（`inject_library:` / `remote_dlopen:` 等），
   `remote_dlopen` 的 dlopen 回退分支拆分更细，`main` 的失败日志带 stage 说明。exact 模式的
   `APATCH_INJECT_LIBRARY_FD` 校验块语义不变，适配新的日志/校验结构。
3. **控制 socket 从抽象 socket 改为 keystore_data_file 内文件系统 socket**：sepolicy 需要的
   不只是 `connectto`，还有对端域的 `keystore_data_file dir search` + `sock_file` 访问；
   daemon 侧域从“su/magisk/ksu”扩展为“su/ksu/system_server”。
4. **sepolicy.rule 大幅扩充**（WebUI admin socket、logd 直读、staging 回退、keystore_data_file）。

## 每个文件的融合决策

### module/daemon（0032 语义，逐字移植）
canary-76 的 daemon 与 v4.0 基线一致，`--exec-context-privileged` bounded-exec 分支 + `app_process64`
优先 + 普通 `app_process` 回退直接套用。能力检测用 `su --help | grep -- '--exec-context-privileged'`，
不要用 `/data/adb/apd` 存在性判断。

### module/customize.sh（0047 语义）
`su --no-pty --inject-capable` 成功 → 删除已安装的 `sepolicy.rule` + 落
`.apatch_exact_inject_v1` 标记（exact 模式零持久化策略）；失败 → 清除标记。删除规则同时保证定制
APatch 的模块扫描永远看不到 `magisk` 类型引用（0045 的降级触发条件）。

### module/sepolicy.rule（0045 语义适配到新规则结构）
- **删除了所有 `magisk` 类型引用**（`allow magisk ...`、`allow su magisk ...`、`allow magisk su ...`）：
  定制 APatch 把活动模块中的 `magisk` 引用判定为 legacy-root 依赖，将 IReZygisk hidden
  `minimal-v1` 降级为 `minimal-v0`，拒绝启动 domainless early-loader。即使 exact-inject 检测在
  安装期失败（规则文件保留的降级路径），加载本文件也不会触发降级。
- **新增 `system_server` 作为 daemon 侧对端域**：bounded-exec 把 daemon 送进
  `u:r:system_server:s0`，覆盖 ① 控制 socket 的 `connectto` + `keystore_data_file dir/sock_file`，
  ② WebUI admin socket 的 self 监听 + `adb_data_file sock_file`（su/ksu shell → system_server
  `connectto`），③ logd 直读的 `connectto` + `logdr_socket sock_file write`。
- **保留 `su`/`ksu` 对端规则**：KernelSU、上游 APatch 的 daemon 仍跑在 root-manager 域。
  （旧分支把 su 也删了；本分支保留以维持上游 APatch/KernelSU 兼容，Magisk 的控制通道因
  magisk 规则移除而牺牲，与旧分支一致。）
- keystore 侧规则（self socket、keystore_data_file sock_file、crash_dump ptrace、
  adb_data_file 映射、shell_data_file staging 回退）保持 canary-76 原样。

### app/src/main/java/org/matrix/teesim/Injector.kt（0047 语义）
- `exactInject` 标记位 = module 目录下 `.apatch_exact_inject_v1`；
- `start()`：标记存在但 `su --inject-capable` 失败 → 拒绝启动注入循环（fail closed）；
- `inject()`：运行期再次校验能力，消失则拒绝 legacy 回退；exact 模式命令为
  `su --no-pty -p --inject-target <pid> --inject-library <lib> -- inject <pid> <lib> entry`
  （独立 argv，无 `su -c` 拼接）；
- 保留 canary-76 的 lastPid 快查、`serviceReady()`、`confirmAsync()` 与 `Injector:` 日志风格。

### injector/main.cpp（0047 语义）
- `main()`：检测 `APATCH_INJECT_LIBRARY_FD` → strict 校验（非 CLOEXEC、regular file、ELF
  magic/endianness/class/e_type==ET_DYN）→ argv[2] 仅为 display-only（绝不 realpath/open/staging）；
  无环境变量 → 走上游 legacy realpath 校验。
- `transfer_fd_to_remote` / `remote_dlopen` / `inject_library` 增加 inherited-fd 与
  `allow_path_fallback` 参数；exact 模式下 `android_dlopen_ext` 缺失或 fd 传递失败 → 直接失败
  （禁止 dlopen(path) 与 /data/local/tmp staging）。
- exact 模式的逻辑加载名为 `libteesim-apatch-inherited.so`（bionic 显示名，字节全部来自 fd）。

### module/service.sh（主题崩溃防护，非补丁内容，设备实测要求）
MI9/MIUI A11 上 daemon 经 `ConfigManager.openDb → SQLiteGlobal → Resources.getSystem →
MiuiResources → ThemeCompatibility.<clinit>` 链读取硬编码的
`/data/system/theme_config/theme_compatibility.xml`，文件缺失时 ENOENT 崩溃循环。启动 daemon 前，
该文件不存在时从 `/system/media/theme/`（`/product/media/theme/` 兜底）复制并
`chown system:system`、dir 770 / file 660（参考 ckbsmart smartLoader 实现）。

### 版本策略（0032 语义，基名适配 canary-76）
- `versionCode = 40000 + git 提交数`（高于官方 line，防降级提示）。
- `versionName = canary76-ckb-apatch1`。
- 移除 `updateJson`，防止官方包静默覆盖定制启动链。
- 新增 `.gitattributes` 强制 `module/daemon`、`*.sh` LF，避免 Windows 构建产物脚本在设备上
  shebang 解析失败。

## 构建与设备验证风险点（未构建、未刷机）

1. **exact 模式下 keystore 侧权限依赖定制 APatch 的事务授权**：规则文件已删，keystore 映射
   inherited-fd .so、绑定 keystore_data_file 控制 socket 依赖定制 APatch 的 bounded
   transaction 覆盖面。canary-76 把控制 socket 从抽象 socket 改为文件系统 socket，若事务授权
   未覆盖 sock_file bind，需在定制 APatch 侧补事务范围（不得回写 sepolicy.rule，否则破坏隐藏）。
2. **`su --inject-capable` / `--exec-context-privileged` 探测在安装期的可用性**：安装器 shell
   必须已被管理器授权 root；失败会走降级路径（daemon 仍 bounded-exec 进 system_server，
   但注入走 legacy 且无 exact 标记 → Injector 拒绝启动并留 error 日志）。
3. **injector/main.cpp 的 exact 编译**：`<cstddef>/<cstdint>` 已补；`offsetof(Elf32_Ehdr/Elf64_Ehdr)`
   依赖 `elf.h`（canary-76 已含）。x86_64 与 arm64 两个 ABI 都要编译通过。
4. **MI9 A11 legacy keystore**：procName/libName 按 SDK 分支逻辑未动，theme 修复要验证
   `/system/media/theme/` 与 `/product/media/theme/` 哪个存在。
5. **WebUI admin socket 跨域连接**：`su/ksu → system_server connectto` 规则首次使用，
   若 WebUI 无法连通 admin socket，查 `avc: denied connectto` 日志再补规则。

## 不要重复踩的坑（canary-76 增补）

- 上游再重构 Injector.kt / main.cpp 时，exact 模式的三个不变量：标记文件决定模式；
  运行期能力消失必须 fail closed；display-only 路径绝不许被 reopen/staging。
- sepolicy.rule 任何改动都不得重新引入 `magisk` 类型引用——会静默打断 IReZygisk domainless。
- 升级上游后必须重核 `module/daemon`（上游覆盖 APatch 分支）与 `module/customize.sh`
  （exact-inject 探测块）两处。
