# TEESimulator canary-76 移植施工指南（多 agent 并行）

> 基线 = ckb-canary-76-baseline（官方 canary-76 06f9f2e）
> 适配源 = 旧 ckb-apatch-v4.0 分支（基于 08-21 快照 + 50 提交）→ 已生成 47 补丁
> 目标 = 官方最新代码 + 定制 APatch 全部适配 = ckb-canary-76 定制版

## 背景速读
- 官方 canary-76 = JingMatrix/TEESimulator 最新（10-23），KeyMint TA 架构
- MI9 A11 legacy keystore 上 TrickyStoreOSS 被 momo 识别 → TEESimulator 是替代底层
- 旧分支适配了：定制 APatch bounded-exec 注入 / Windows 构建链 / 多 ABI Rust

## 47 补丁分类（建议分工）
| 类别 | 补丁 | 冲突风险 |
|---|---|---|
| Windows 构建链（bindgen/libclang/AIDL/mirror） | 0001~0028 大部分 | 低（build 脚本隔离） |
| APatch domainless 模式 | 0045 | 中（daemon/service.sh 上游大改） |
| **APatch exact injection**（核心） | 0047 | **高**（injector 代码上游重构过） |
| 文档 | 0009/0046 | 无 |

## 施工步骤（每个 agent 一类）
1. `git checkout -b ckb-port <分类分支>` 从 baseline 建
2. 按序 `git am ckb_patches/00XX-*.patch`（冲突手工解决，语义对齐 canary-76 新架构）
3. 全类完成后合流 → 构建验证：`./gradlew :app:assembleRelease`（需 Windows bindgen 环境，参考旧分支的构建补丁）
4. 产物部署 MI9：禁 tricky_store → 装 teesim → config(keybox+目标app) → 重启 → Momo/Hunter 复测

## 关键文件（对照旧分支）
- injector/：APatch exact injection 逻辑（0047 核心）
- module/service.sh：domainless 模式保持（0045）
- module/customize.sh：定制 APatch 检测
- scripts/：Windows 构建链修复

## 验收
- [ ] 全补丁应用完成，构建出 Release zip
- [ ] MI9 装机：daemon 起来（无 theme ENOENT 崩溃——theme_compatibility.xml 修复要带上）
- [ ] keystore 注入成功（logcat: "interceptor installed"）
- [ ] momo 复测 TEE 损坏消失
- [ ] Hunter 复测全绿
