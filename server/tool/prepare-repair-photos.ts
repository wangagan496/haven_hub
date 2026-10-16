import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import sharp from 'sharp';

const directory = resolve('../output/repair-fixtures-20261015');
mkdirSync(directory, { recursive: true });
const selections = [
  ['tap-1', 'File:Dripping faucet 1.jpg'],
  ['tap-2', 'File:Dripping faucet 2.jpg'],
  ['hinge', 'File:Scharnier für Schranktüren1.jpg'],
  ['hinge-pin', 'File:Scharnier lossepen001.jpg'],
  ['window', 'File:Window Handle.jpg'],
  ['window-catch', 'File:Window catch in Haus Wittgenstein.jpg'],
];
const manifest: Array<{key: string | undefined; title: string | undefined; source: string;
  imageUrl: string; author: string; license: string; licenseUrl: string;
  modification: string; usage: string; file: string; bytes: number}> = [];
for (const [key, title] of selections) {
  const query = new URL('https://commons.wikimedia.org/w/api.php');
  Object.entries({ action: 'query', titles: title!, prop: 'imageinfo',
    iiprop: 'url|extmetadata', iiurlwidth: '960', format: 'json' })
    .forEach(([name, value]) => query.searchParams.set(name, value));
  const response = await fetch(query, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`Metadata HTTP ${response.status}`);
  const body = await response.json() as any;
  const page = Object.values(body.query.pages)[0] as any;
  const info = page.imageinfo?.[0];
  if (!info) throw new Error(`Missing photo: ${title}`);
  const imageUrl = info.thumburl ?? info.url;
  const image = await fetch(imageUrl, { signal: AbortSignal.timeout(45000) });
  if (!image.ok) throw new Error(`Photo HTTP ${image.status}: ${title}`);
  const bytes = await sharp(Buffer.from(await image.arrayBuffer()))
    .rotate().resize({ width: 1280, height: 1280, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 88 }).toBuffer();
  writeFileSync(resolve(directory, `${key}.jpg`), bytes);
  const plain = (value: string = '') => value.replace(/<[^>]*>/g, '').trim();
  manifest.push({ key, title, source: info.descriptionurl, imageUrl,
    author: plain(info.extmetadata.Artist?.value),
    license: plain(info.extmetadata.LicenseShortName?.value),
    licenseUrl: info.extmetadata.LicenseUrl?.value,
    modification: 'Resized to at most 1280px and converted to JPEG; metadata removed.',
    usage: 'Related reference photograph for fictional local acceptance-test records; not a photograph of the named home.',
    file: `${key}.jpg`, bytes: bytes.length });
  console.log(JSON.stringify(manifest.at(-1)));
}
writeFileSync(resolve(directory, 'photo-sources.json'), JSON.stringify(manifest, null, 2));
const tiles = await Promise.all(manifest.map(async photo => ({
  input: await sharp(resolve(directory, photo.file)).resize(320, 240, { fit: 'contain', background: '#eeeeee' }).toBuffer(),
  left: (manifest.indexOf(photo) % 3) * 320,
  top: Math.floor(manifest.indexOf(photo) / 3) * 240,
})));
await sharp({ create: { width: 960, height: 480, channels: 3, background: '#eeeeee' } })
  .composite(tiles).png().toFile(resolve(directory, 'contact-sheet.png'));
