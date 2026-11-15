#!/usr/bin/env python3
"""xcodegen 生成工程后，给三个 target 打开 App Groups 能力。

Xcode 的自动签名只有在工程的 TargetAttributes 里声明了能力时，才会去开发者后台
申请带 App Group 的描述文件；xcodegen 默认不写这一段，命令行构建真机包就会报
"Provisioning profile doesn't match ... application-groups"。

用法（在 native/ 目录下）：
    xcodegen generate && python3 scripts/enable-capabilities.py
"""
import pathlib
import re

path = pathlib.Path("DeepSeekNative.xcodeproj/project.pbxproj")
text = path.read_text()

ids = {}
for match in re.finditer(
    r"(\w{24}) /\* (DeepSeekNative|DeepSeekWidgets|DeepSeekShareExt) \*/ = \{\n\t\t\tisa = PBXNativeTarget;",
    text,
):
    ids[match.group(2)] = match.group(1)

block = "TargetAttributes = {\n"
for target_id in ids.values():
    block += (
        f"\t\t\t\t\t{target_id} = {{\n"
        "\t\t\t\t\t\tProvisioningStyle = Automatic;\n"
        "\t\t\t\t\t\tSystemCapabilities = {\n"
        "\t\t\t\t\t\t\tcom.apple.ApplicationGroups.iOS = {\n"
        "\t\t\t\t\t\t\t\tenabled = 1;\n"
        "\t\t\t\t\t\t\t};\n"
        "\t\t\t\t\t\t};\n"
        "\t\t\t\t\t};\n"
    )
block += "\t\t\t\t};"

text = re.sub(r"TargetAttributes = \{.*?\n\t\t\t\t\};", block, text, count=1, flags=re.S)
path.write_text(text)
print("patched App Groups capability for:", ", ".join(f"{k}={v}" for k, v in ids.items()))
