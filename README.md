# Codex Helper 个人维护版

本仓库由 [makerjackie/codex-helper](https://github.com/makerjackie/codex-helper) fork，基于 v0.8.5，保留原作者历史和 MIT 许可证。非 OpenAI 官方项目。

## 本版行为

- 保留菜单栏、主窗口、额度倒计时和小组件，每 5 分钟查询官方额度。查询额度不会提交模型任务。
- 兼容 Codex App 新的内嵌 CLI 路径，保留 OpenAI 开发者签名校验。
- 移除自动重试界面，启动时关闭自动重试，避免自动发送续跑消息。
- 关闭软件自动检查、下载和安装，界面仅打开本仓库。原作者更新由维护者手动审查和合并。
- 每 10 分钟读取 AIHOT 公开重置消息，展示近 7 天记录、新消息标记和 macOS 通知。应用需保持运行；通知需在系统设置中允许。
- 重置时间显示北京时间。第三方预告、网站推算和来源确认分别标注；个人额度以官方查询为准。
- 消息缓存、去重和离线显示均保存在本机。公共消息请求不带 Codex 账号、聊天记录或登录凭据，不执行网页脚本。

## 构建与验证

要求 macOS 13+。仅有 Command Line Tools 时，可运行：

```sh
git clone https://github.com/slowly1111/codex-helper.git
cd codex-helper
./test.sh
./scripts/build-local.sh
```

`build-local.sh` 输出当前 Mac 架构的 `.build/local/Codex Helper.app`，采用本地临时签名，不包含 Widget 扩展，不自动安装。完整应用和 Widget 构建需要 Xcode：

```sh
./scripts/build.sh
```

完整构建默认使用临时签名。分发时请使用维护者自己的签名身份和 App Group；本仓库不包含原作者的签名私钥，也不宣称个人构建经过 Apple 公证。

`./test.sh` 编译应用、运行原有自测和离线边界测试、检查配置和项目文件；有完整 Xcode 时额外验证包含 Widget 的构建。测试不提交 Codex 消息，不访问个人账号，不调用模型，不改用户配置。

本机安装版本延续原有 bundle ID 和数据目录，以保留设置。若将来要与原版并行安装，需一并迁移主应用及 Widget 的 bundle ID、App Group、登录项和通知设置。

## 手动维护上游

本仓库没有定时同步或自动合并流程。`origin` 指向个人仓库，`upstream` 指向原作者仓库。仅在决定检查上游时执行：

```sh
git remote add upstream https://github.com/makerjackie/codex-helper.git
git fetch upstream
git log --oneline main..upstream/main
git diff main...upstream/main
git switch -c review-upstream
git merge upstream/main
./test.sh
```

已有 `upstream` 时跳过添加。检查差异、处理冲突并验证通过后，再自行合并和推送。重点复核自动重试、更新入口、签名要求以及外部消息接口。

离线消息样本位于 `Tests/Fixtures/ResetNotices/`，仅包含 AIHOT 的公开 API 响应。原项目文档与宣传素材保留为历史资料，其中自动重试和自动更新说明不代表本版行为。

本版核心运行链路的优化、117 项边界检查及验证范围见 [2026-10-24 对抗性审查记录](docs/review-2026-10-24.md)。
