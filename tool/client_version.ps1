function Get-HavenClientVersion {
  param([string] $PubspecPath, [string[]] $Arguments)
  $text = Get-Content -LiteralPath $PubspecPath -Raw
  $match = [regex]::Match($text, '(?m)^version:\s*([^\s+]+)(?:\+[^\s]+)?\s*$')
  if (-not $match.Success) { throw 'pubspec.yaml must declare a release version' }
  $version = $match.Groups[1].Value
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    if ($Arguments[$index] -eq '--build-name') {
      if (++$index -ge $Arguments.Count) { throw '--build-name requires a version' }
      $version = $Arguments[$index]
    } elseif ($Arguments[$index].StartsWith('--build-name=')) {
      $version = $Arguments[$index].Substring('--build-name='.Length)
    }
  }
  if ($version -cnotmatch '^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$') {
    throw 'Client version must be a canonical major.minor.patch release version'
  }
  return $version
}
