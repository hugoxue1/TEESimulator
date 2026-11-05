# CKB 移植状态（hugoxue1 定制版）

> 本文档说明当前仓库（分支 `ckb-canary-76` 系列）的定制版定位、与上游的差异、
> MI9 部署要点与关键实验结论。移植施工总纲见 `ckb_patches/PORTING_GUIDE.md`；
> 定制 APatch 适配的完整说明见 `docs/APatch_定制适配说明_2026-08-21.md`。

## 定制版定位

- 这是 **hugoxue1 定制版**，不是 JingMatrix/TEESimulator 官方发布物。
- 上游基线：官方 **canary-76**（提交 `06f9f2e`，2026-10-23 前后的 KeyMint TA 架构版本），
  对应远程分支 `hugoxue/ckb-canary-76-baseline`。
- 在该基线上叠加旧 `ckb-apatch-v4.0` 分支（基于 08-21 快照 + 50 提交）产出的
  **47 个适配补丁**（见 `ckb_patches/`），内容覆盖：
  - 定制 APatch 适配（bounded-exec daemon 启动 / exact injection / domainless 模块模式）；
  - Windows 构建链修复（bindgen / libclang / AIDL / Gradle 与 AOSP 镜像 / 多 ABI Rust）；
  - Android 10/11 legacy keystore 支持与 per-profile 控制通道等旧分支功能。
- 目标：官方最新代码 + 定制 APatch 全部适配 = **ckb-canary-76 定制版**，
  在 MI9（MIUI A11，legacy keystore）上作为 TrickyStore 系方案的替代底层。

## 本分支（ckb-port-docs）文档类补丁移植清单

| 补丁 | 处置 | 说明 |
|---|---|---|
| 0009 Add the Kotlin control daemon（docs 部分） | **SKIP** | 该补丁不含任何 `docs/` 内容（全部为 `app/`、`stub/` 的 Kotlin/Java/Gradle 代码），无文档部分可移植。 |
| 0027 Add the project documentation | **SKIP** | 上游 canary-76 已自带等价项目文档：根 `README.md` 及 `app/`、`injector/`、`keymint/`、`keystore/`、`rust/teesim-km/`、`third_party/` 的 `README.md` 均存在且为重写后的正式版本。 |
| 0040 docs: record Windows bindgen dependency | **应用** | 其基座文档 `docs/APatch_定制适配说明_2026-08-21.md` 上游不存在，随本分支一并移植（基座取自 0032 的 docs hunk，并按序叠加 0033~0046 各补丁的 docs hunks，使 0040/0044/0046 的上下文完整成立）。 |
| 0044 docs: record multi-ABI Rust targets | **应用** | 同上；内容为 `arm64-v8a` + `x86_64` 双 Rust target 的构建说明。 |
| 0046 docs: record TEESimulator live-policy visibility gap | **应用** | 同上；内容为 live-policy 计数痕迹（`STATUS_SEQUENCE_POLICYLOAD` / `RAW_AVD_SEQUENCE`）这一未消除隐藏面的如实记录。 |

注：为使 0040/0044/0046 可直接施加，本分支同时带入了中间补丁（0033/0034/0036~0039/
0041~0043/0045）对同一文档的 docs hunks——这些补丁的**代码部分**不属于本分支范围，
由其他移植分支按 PORTING_GUIDE 分类处理。

## 定制 APatch 差异点

本定制版面向的 Root 管理器是 **hugoxue1 定制 APatch**（内核 KernelPatch + 定制 apd），
与上游/官方 APatch 有三处关键差异，移植或排障时必须核对这些前提：

### 1. bounded privileged-exec API（daemon 启动依赖）

- 定制 APatch 的 `su` 提供私有参数 `--exec-context-privileged`，可在精确 exec 时把
  daemon 任务树过渡到 `u:r:system_server:s0` 域并恢复长期 Java 进程所需权限：

  ```text
  su --no-pty -p --exec-context-privileged u:r:system_server:s0 -- \
      /system/bin/app_process64 -Djava.class.path=... ...
  ```

- TEESimulator 的 shell 服务最终会再执行一次 `app_process`；普通 root shell 跨过这次
  exec 后**不能**自动保留 daemon 所需权限（表现为启动即退、读 `/data/adb` 失败、注入
  或控制通道不完整）。因此 daemon 必须经由上述 bounded-exec 路径启动。
- 所有参数以独立 argv 传递，不经 `su -c` 拼接；优先 `app_process64`，缺失才回退
  `app_process`。检测方式是 `su --help` 是否含该参数，**不能**只判断 `/data/adb/apd`
  是否存在。

### 2. domainless 模块模式（sepolicy 规则收敛）

- 定制 APatch 会把任何活动模块 `sepolicy.rule` 中的 `magisk` 类型引用判定为
  legacy-root 依赖，将隐藏优先级 `minimal-v1` **降级为 `minimal-v0`**，继而拒绝启动
  IReZygisk domainless early-loader（症状：TEESimulator 正常运行，但 IReZygisk
  monitor / zygiskd / 插件均不加载）。
- 因此模块策略不再保留上游面向通用 root 管理器的 `allow magisk ...` 兼容规则，控制端
  连接权限收窄为 `allow system_server keystore unix_stream_socket connectto`，与
  bounded-exec 的运行域保持一致。

### 3. 与上游 APatch 的区别小结

| 能力 | 定制 APatch | 上游/官方 APatch |
|---|---|---|
| `su --exec-context-privileged` | 有（私有 bounded-exec API） | 无 → daemon 走上游原生 `app_process` 启动，权限可能不足 |
| `magisk` 类型引用 | 视为 legacy-root 依赖，触发 `minimal-v1→v0` 降级 | 允许 `magisk` 兼容规则 |
| domainless early-loader | 要求模块策略不引用 `magisk` 才启动 | 无此耦合 |

其余隐藏/权限边界（无专用 SELinux 域、无 permissive、既有隐藏逻辑不动）与
live-policy 计数痕迹这一**未消除**项，见 `docs/APatch_定制适配说明_2026-08-21.md`
的「隐藏与权限边界」与「未完成：live-policy 计数痕迹」两节。

## MI9 部署注意事项（MIUI A11 / Android 11 / legacy keystore）

1. **`/data/system/theme_config/theme_compatibility.xml` 必须存在。**
   MIUI A11 上缺失该文件会使 daemon 启动即崩溃（theme 相关 ENOENT）；
   部署前确认该文件在位，这是 MI9 daemon 能起的前提。
2. **daemon 需经 APatch bounded-exec 转换。**
   普通 root shell 直接拉起 daemon 会在 `app_process` 二次 exec 后掉权限、静默死亡
   （零日志零进程）。必须走 `su --no-pty -p --exec-context-privileged
   u:r:system_server:s0 -- app_process64 ...` 路径（见上文差异点 1）；
   另注意 A11 必须用真 APK 做 CLASSPATH（service.apk），裸 classes.dex 会
   `ClassNotFound:MainKt`。
3. **keybox 与验证目标配置。**
   - keybox 放 `/data/adb/teesim/keybox.xml`；
   - `/data/adb/teesim/config.json` 的目标 app 列表需包含
     `io.github.vvb2060.mahoshojo`（Momo）与 `com.zhenxi.hunter`（Hunter），
     用于装机后直接复测验证；
   - 不要同时启用 TrickyStore 与 TEESimulator Hook keystore（上游安装脚本主动禁用
     TrickyStore 是有意的冲突保护）。

## 2026-11-05 实验结论：为什么 MI9 选 TEESimulator

- **TrickyStoreOSS（LEAF_HACK 架构）在 MI9 legacy keystore 上被 momo v4.4.1 识别。**
  11-05 实验中，即便 TS daemon 存活、已注入 keystore（maps 可见
  `libTrickyStoreOSS.so`）、keybox 正常加载，TS 对第三方 app 的 attestation 服务在
  MIUI A11 legacy keystore 上仍不产出有效响应；Momo 读到注入痕迹后直接判定
  **TEE 损坏**。禁用 TS（真 TEE 直出）后 Momo 即恢复正常——即「报 TEE 损坏」
  本质是 Momo 识别到了 TS 的注入/服务行为，而非 keybox 或检测器缺口。
- **TEESimulator（KeyMint TA 架构）是替代方案。** 它在 keystore 进程内嵌 AOSP 参考
  KeyMint TA（`kmr-ta`）并用用户 keybox 签发 attestation，证书链与真 TEE 同构，
  服务质量与痕迹形态与 TS 的 LEAF_HACK 不同，是 MI9 legacy keystore 上的替代底层。
  本定制版（canary-76 基线 + APatch 适配）即为该方案的移植载体。
- 注意 217 号档同时指出：MI9（bootloader 锁定 + APatch 内核补丁）真 TEE 直出本身
  即为三方检测最优解，伪造反而可能是降级；TEESimulator 的适用前提是确需对目标 app
  供给可控 attestation（如指纹/系谱定制）。选型前先读该档 §7.1 的 A/B 结论。
- **详见 `docs/工程项目总览/217` 号档：**
  `E:\ckb_workspace\docs\工程项目总览\217_A13模块批量禁用与TrickyStore双重坑_2026-11-05.md`
  （仓外工作区文档），重点 §7.1：§7.1c-bis（MI9 同症状异根因与 momo TEE 损坏定位）、
  §7.1e-bis（11-05 13:35 MI9 A/B 实测终局反转：真 TEE 直出最优、TS 类伪造的适用边界）。

## 相关文档索引

- `docs/APatch_定制适配说明_2026-08-21.md` —— 定制 APatch 适配全记录（含 Windows
  构建链、多 ABI Rust、live-policy 可见性缺口）。
- `ckb_patches/PORTING_GUIDE.md` —— 47 补丁分类、分工与验收清单。
- `README.md` —— 上游项目文档（架构/安装/配置）。
