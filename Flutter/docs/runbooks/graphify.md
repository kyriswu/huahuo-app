# Graphify 项目工具链

Python 版本由系统级 uv 管理；Graphify 的版本、依赖锁和提取规则由本项目
管理。`tool/graphify/pyproject.toml` 声明直接依赖，`uv.lock` 锁定传递依赖。
项目隔离环境在 `tool/graphify/.venv/`，与生成图一样被 Git 忽略。不依赖
也不要求全局 `graphify` 命令，不在业务 pubspec 中添加 Python 工具。

安装好用户级 uv 后，在 Flutter workspace 中执行：

```sh
sh tool/graphify.sh refresh
sh tool/graphify.sh explain billingControllerProvider --graph graphify-out/graph.json
sh tool/graphify.sh affected billingControllerProvider --graph graphify-out/graph.json --depth 1
```

入口使用 `uv run --locked`，首次按锁文件建立隔离环境；配置与锁文件不一致
就失败，不静默更新锁。Python 3.13 是工具兼容要求，由 uv 管理的解释器提供，
不将 Python 二进制放入项目。多项目可以有不同 Graphify 版本，互不覆盖。
不要直接运行全局 Graphify 或裸 `python3 tool/graphify_refresh.py`。

需要升级时，单独修改 pyproject.toml 的版本约束，再运行
`uv lock --project tool/graphify --python 3.13 --managed-python`，审阅锁文件
及提取差异后提交。`.venv` 可删除并按锁文件重新创建，不能手改其内容。

刷新使用 code-only/no-cluster，不调用模型；包含移动、桌面、共享包、测试
与原生代码，排除资源目录、第三方代码、历史文档和构建缓存。输出目录被
Git 忽略。provenance 记录工作树、源码和图散列、工具锁散列与解释器版本，
实际安装依赖保存在 environment.txt。不要仅凭 HEAD 判断工作树图是否过期。
重构前可把 graphify-out 复制到仓库外临时目录保存对照。

删除较多代码或需要完整重提取时，确认范围后执行
`sh tool/graphify.sh refresh --force`。检查 refresh.log，不用强制提取掩盖
解析失败。重名符号使用 node ID。Dart 提取为启发式，provider、回调、
路由、跨包导入和原生通道可能遗漏，必须继续用源码、analyzer 和测试核查。
图不是编译证明或联调证据。不生成源码 Markdown 镜像，不安装自动 hooks。
