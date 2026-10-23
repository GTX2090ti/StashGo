#!/usr/bin/env python3
"""修补 flutter_embedding_*.har 内的 OhosAutoFillHelper.ets。

Flutter-OH 3.35.7 的 embedding 使用了 autoFillManager 在 API 26 才引入的
AutoFillType / ViewData / FillRequest / AutoFillCallback / FillFailureResult /
SaveRequest / requestAutoFill。命令行工具最高只到 API 24，CompileArkTS 会报错。

做法：把 SDK 类型换成文件内本地定义的结构镜像，真实 API 调用改成 ESObject
动态调用（原有 sdkApiVersion < 26 的运行时守卫会拦住旧设备）。
脚本幂等，可重复执行；首次修改前会备份为 *.har.orig。
"""
import glob
import os
import shutil
import sys
import tarfile
import tempfile

HAR_GLOB = "/opt/flutter/bin/cache/artifacts/engine/ohos-*/flutter_embedding_*.har"
REL_PATH = "package/src/main/ets/plugin/editing/OhosAutoFillHelper.ets"
MARKER = "interface SdkFillRequest"

MIRRORS = '''
// Local structural mirrors of the autoFillManager (API 26) types. They keep the embedding
// compilable against older SDKs; calls into the real API are made dynamically at runtime
// and are already guarded by AUTOFILL_SUPPORT_API.
interface SdkFillFailureResult {
  errCode: number;
}

interface SdkAutoFillCallback {
  onSuccess: (viewData: AutoFillManagerViewData) => void;
  onFailure: (result: SdkFillFailureResult) => void;
}

interface SdkFillRequest {
  type: number;
  viewData: AutoFillManagerViewData;
  customData: AutoFillCustomData;
  isPopup: boolean;
  triggerType: number;
}

interface SdkSaveRequest {
  viewData: AutoFillManagerViewData;
}
'''

REPLACEMENTS = [
    (
        "  autoFillType: autoFillManager.AutoFillType;\n",
        "  autoFillType: number;\n",
    ),
    (
        "interface AutoFillCustomData {\n"
        "  data: Record<string, string>;\n"
        "}\n",
        "interface AutoFillCustomData {\n"
        "  data: Record<string, string>;\n"
        "}\n" + MIRRORS,
    ),
    (
        "  private static toSdkAutoFillType(value: number): autoFillManager.AutoFillType {\n"
        "    return value as autoFillManager.AutoFillType;\n"
        "  }\n",
        "  private static toSdkAutoFillType(value: number): number {\n"
        "    return value;\n"
        "  }\n",
    ),
    (
        "  private static toManagerViewData(viewData: OhosViewData): autoFillManager.ViewData {\n",
        "  private static toManagerViewData(viewData: OhosViewData): AutoFillManagerViewData {\n",
    ),
    (
        "    return managerViewData as autoFillManager.ViewData;\n",
        "    return managerViewData;\n",
    ),
    (
        "  static parseFillResult(viewData: autoFillManager.ViewData): Map<number, string> {\n"
        "    const values: Map<number, string> = new Map();\n"
        "    const pageNodeInfos: OhosPageNodeInfo[] =\n"
        "      (viewData as AutoFillManagerViewData).pageNodeInfos;\n",
        "  static parseFillResult(viewData: AutoFillManagerViewData): Map<number, string> {\n"
        "    const values: Map<number, string> = new Map();\n"
        "    const pageNodeInfos: OhosPageNodeInfo[] = viewData.pageNodeInfos;\n",
    ),
    (
        "      triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST as autoFillManager.AutoFillTriggerType,\n"
        "    } as autoFillManager.FillRequest;\n"
        "    const callback: autoFillManager.AutoFillCallback = {\n"
        "      onSuccess: (filledViewData: autoFillManager.ViewData): void => {\n",
        "      triggerType: AUTOFILL_TRIGGER_AUTO_REQUEST,\n"
        "    } as SdkFillRequest;\n"
        "    const callback: SdkAutoFillCallback = {\n"
        "      onSuccess: (filledViewData: AutoFillManagerViewData): void => {\n",
    ),
    (
        "      onFailure: (result: autoFillManager.FillFailureResult): void => {\n",
        "      onFailure: (result: SdkFillFailureResult): void => {\n",
    ),
    (
        "      autoFillManager.requestAutoFill(uiContext, fillRequest, callback);\n",
        "      (autoFillManager as ESObject).requestAutoFill(uiContext, fillRequest, callback);\n",
    ),
    (
        "    const saveRequest: autoFillManager.SaveRequest = {\n",
        "    const saveRequest: SdkSaveRequest = {\n",
    ),
    (
        "      autoFillManager.requestAutoSave(uiContext, saveRequest, napiCallback);\n",
        "      (autoFillManager as ESObject).requestAutoSave(uiContext, saveRequest, napiCallback);\n",
    ),
]


def patch_source(src: str) -> str:
    if MARKER in src:
        return src
    out = src
    for old, new in REPLACEMENTS:
        count = out.count(old)
        if count != 1:
            raise RuntimeError(f"替换锚点出现 {count} 次（期望 1）：{old.splitlines()[0]}")
        out = out.replace(old, new)
    return out


def patch_har(har: str) -> bool:
    tmp = tempfile.mkdtemp()
    try:
        with tarfile.open(har, "r:gz") as tar:
            tar.extractall(tmp)
        target = os.path.join(tmp, REL_PATH)
        if not os.path.exists(target):
            print(f"skip (no {REL_PATH}): {har}")
            return False
        with open(target, encoding="utf-8") as f:
            src = f.read()
        patched = patch_source(src)
        if patched == src:
            print(f"already patched: {har}")
            return False
        with open(target, "w", encoding="utf-8") as f:
            f.write(patched)
        if not os.path.exists(har + ".orig"):
            shutil.copy2(har, har + ".orig")
        out = har + ".new"
        with tarfile.open(out, "w:gz") as tar:
            tar.add(os.path.join(tmp, "package"), arcname="package")
        shutil.move(out, har)
        print(f"patched: {har}")
        return True
    finally:
        shutil.rmtree(tmp)


def main() -> int:
    hars = sorted(glob.glob(HAR_GLOB))
    if not hars:
        print("未找到 flutter_embedding HAR，请先执行 flutter precache --ohos", file=sys.stderr)
        return 1
    changed = 0
    for har in hars:
        changed += 1 if patch_har(har) else 0
    print(f"完成：{len(hars)} 个 HAR，改动 {changed} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
