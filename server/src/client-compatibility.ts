import type { RequestHandler } from 'express';

// Bounded canonical release triples; prereleases/build suffixes are not policy versions.
export const clientVersionPattern = /^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$/;
const platforms = new Set(['ohos', 'web', 'android', 'ios', 'linux', 'macos', 'windows', 'fuchsia', 'admin-web']);

export function clientCompatibility(minimumVersion: string): RequestHandler {
  const minimum = minimumVersion.split('.').map(Number);
  return (request, response, next) => {
    if (!minimumVersion) { next(); return; }
    const version = request.get('X-Client-Version') ?? '';
    const platform = request.get('X-Client-Platform') ?? '';
    const parts = version.split('.').map(Number);
    const difference = parts.map((part, index) => part - minimum[index]!).find(value => value !== 0) ?? 0;
    if (clientVersionPattern.test(version) && platforms.has(platform) && difference >= 0) {
      next();
      return;
    }
    // Metadata describes compatibility, never identity/authorization. Admin is not exempt.
    response.status(426).json({ code: 42600,
      message: `当前客户端版本不受支持，请升级至 ${minimumVersion} 或更高版本；请联系物业获取更新，本次操作未受理`,
      data: { minimumVersion } });
  };
}
