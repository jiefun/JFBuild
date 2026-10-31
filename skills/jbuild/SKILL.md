---
name: jbuild
description: 使用 JFBuild 为 iOS 项目完成接入、配置、归档、导出 IPA、上传蒲公英或 App Store Connect、上传 Bugly 符号表和钉钉通知。用户要求使用 jbuild 打包、复用归档补传或排查打包失败时使用。
---

# JFBuild

通过项目的 `jbuild` 命令执行任务。命令与字段以项目实际安装版本的 `--help`、`README.md` 和 `templates/config.yml` 为准。

## 定位与接入

- 以 App 项目的 `Podfile` 所在目录为工作目录，不把 Skill 所在目录当作 App 目录。
- 已有根目录 `jbuild` 时，先运行 `./jbuild --help`；后续使用这个入口。
- 首次接入时，在现有 Podfile 中添加 `pod 'JFBuild'`，执行 `pod install`，再运行 `./Pods/JFBuild/jbuild init`。
- `init` 生成项目的 `.agents/skills/jbuild/SKILL.md` 入口；它定位当前安装的完整 Skill，操作说明和 README 保留在组件中。已有项目入口会保留。
- 本地 `:path` 安装不会生成 `Pods/JFBuild`。从 `Pods/Manifest.lock`（缺失时读 `Podfile.lock`）的 `EXTERNAL SOURCES` 中读取 JFBuild 的 `:path`，相对于 App 项目目录解析，用该源码目录下的 `jbuild init` 初始化。之后仍用 `./jbuild`。
- 普通 Pod 的文档和模板位于 `Pods/JFBuild/`；本地依赖则读取上述源码目录中的文件。

## 填写配置

编辑 App 项目的 `jfbuild/config.yml`，保留已有值和注释，只补充本次需要的配置。

- `init` 会补充唯一的工程与共享 App Scheme；多个候选写在注释中。结合用户指定的 Target 和工程内容选择，不按候选顺序猜选。
- Apple P8 放在 `jfbuild/keys/`；需要导入签名材料时，可自行创建 `jfbuild/signing/`。Bugly 经典版默认使用内置 JAR，`tool_path` 可留空；专业版或自定义 JAR 可放在 `jfbuild/tools/` 并填写路径。路径相对于 App 项目目录，也支持绝对路径和 `~/`。
- 已有可用的本机签名材料时，可以沿用工程签名。平台密钥、证书和密码使用用户提供或项目已有的材料，不填模板示例值冒充真实配置；不把材料目录加入 App Target。
- 字段填写完整仅表示配置齐全，证书、账号权限及文件有效性仍由执行时验证。
- 遇到配置格式不兼容，按工具提示使用 `./jbuild config update`，检查备份及保留的字段，不直接修改 `config_version` 绕过检查。

## 选择并执行流程

根据用户需求和已有授权确定包类型、更新内容、上传目标及是否通知钉钉。仅要求配置或排查时，不启动打包或上传；凭证已填写不等于本次授权使用所有平台。缺少影响执行范围的信息时，一次问清。

AI 执行时优先使用快捷命令，开发包和正式验收包通过 `--desc` 提供本次更新内容。可以根据本次代码改动整理说明；已有用户文案时沿用。将说明作为一个参数传入，保留换行和特殊字符。

| 需求 | 完整流程命令 |
| --- | --- |
| 开发包 | `./jbuild dev --desc='本次更新内容'` |
| 正式验收包 | `./jbuild release --desc='本次更新内容'` |
| App Store 包 | `./jbuild appstore` |

开发包和正式验收包默认走蒲公英，App Store 包上传到 App Store Connect；审核和正式发布另行操作。构建配置与导出方式读取项目的 `modes`；Bugly 仅在实际构建配置为 Release 时参与。

完整流程会执行已配置的可选上传与通知，缺少配置则跳过。按本次范围添加 `--no-pgyer`、`--no-bugly`、`--no-dingtalk`，不要为临时跳过删除项目凭证。例如只生成本地正式验收 IPA：

```bash
./jbuild release --desc='本次更新内容' --no-pgyer --no-bugly --no-dingtalk
```

只归档或只导出时使用 `archive --mode=包类型`、`export --mode=包类型 --archive=路径`。App Store 完整流程必须上传 Apple；只需要本地商店产物时使用归档／导出命令。

新归档会按 `keep_archives` 清理旧记录，包含其中的 IPA、dSYM 和日志。需要补传或重新导出时，复用已选定产物。

## 使用已有产物

从配置的 `output.directory` 查找 `record.json` 和结果文件，核对包类型、版本、构建配置、创建时间及更新内容。使用用户给定或已明确选定的归档／IPA；选择不明确时列出候选供用户选择，不自动挑最新，也不把 Debug 归档当作 Release。

以下示例假定选定记录的包类型为 `release`；实际命令使用该记录的原包类型，路径替换为选定产物的真实路径。

```bash
# 从已有归档重新导出，再继续对应流程
./jbuild release --archive='/产物目录/App.xcarchive' --desc='本次更新内容'

# 复用已有 IPA，跳过归档和导出，再继续对应流程
./jbuild release --archive='/产物目录/App.xcarchive' --ipa='/产物目录/App.ipa' --desc='本次更新内容'
```

只补传某个平台时使用 `--help` 中对应的 `upload-*` 命令，避免重复执行其他平台和通知；单独发送钉钉使用 `notify --desc=通知内容`。上传失败后，先核对已有执行结果；超时且远端结果不明确时，先确认是否已接收，再决定补传。

## 排错与交付

- 从终端给出的 `result.json` 或对应 `results/*.json` 查看失败步骤，再读取该次 `logs/` 中的日志。日志序号是外部命令执行顺序，不固定对应某个步骤；按操作名和报告路径定位。
- 区分归档、导出、上传和通知的结果。某一步成功不能代表整个流程成功；先报告已完成的部分，再说明剩余问题。
- 修复原因后，从用户选定的产物继续所需步骤，不因上传失败重新归档。仅查看原因时，不修改工程签名、包名或平台账号。
- 最终提供 IPA／归档路径、已返回的下载链接、失败原因及必要的日志路径。不回显 API Key、Webhook 令牌、签名密钥或密码。
