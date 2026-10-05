Provider PNGs are the largest PNG frames extracted without modification from
`Scripts/WindowsProviderIcons/*.ico`. Those files are generated from the original
CodexBar provider SVGs by `Scripts/build_windows_provider_icons.swift`.
Run that script on macOS to refresh both asset directories. It follows the upstream
provider catalog and descriptor branding, including shared artwork, and removes
obsolete provider assets.

`codexbar.ico` contains a 32px rendering of `Icon.icon/Assets/codexbar.png`.
