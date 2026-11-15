/**
 * 文件导出：浏览器里走 <a download>，iOS 原生容器里走「写入缓存目录 + 系统分享面板」。
 *
 * WKWebView 不支持 Blob 下载，直接点链接没有任何反应，所以原生下改为
 * 把文件交给 UIActivityViewController，用户可以存到「文件」App、发微信等。
 */
import { Capacitor } from '@capacitor/core'

export const isNativeApp = Capacitor.isNativePlatform()

const downloadInBrowser = (blob: Blob, filename: string) => {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

const blobToBase64 = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error ?? new Error('read blob failed'))
    reader.onload = () => {
      const result = String(reader.result)
      // dataURL 的格式是 data:<mime>;base64,<data>
      resolve(result.slice(result.indexOf(',') + 1))
    }
    reader.readAsDataURL(blob)
  })

/** 保存/分享一个 Blob；原生下返回分享是否完成，用户取消时抛出的错误会被吞掉 */
export const saveBlob = async (blob: Blob, filename: string) => {
  if (!isNativeApp) {
    downloadInBrowser(blob, filename)
    return
  }
  const { Filesystem, Directory } = await import('@capacitor/filesystem')
  const { Share } = await import('@capacitor/share')
  const path = `exports/${filename}`
  await Filesystem.writeFile({
    path,
    data: await blobToBase64(blob),
    directory: Directory.Cache,
    recursive: true,
  })
  const { uri } = await Filesystem.getUri({ path, directory: Directory.Cache })
  await Share.share({
    title: filename,
    files: [uri],
  }).catch((error: unknown) => {
    // 用户点了取消不算失败
    if (error instanceof Error && /cancel/i.test(error.message)) {
      return
    }
    throw error
  })
}
