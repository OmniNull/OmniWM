# OmniShell styles

Optional desktop styles live here, one folder per style. OmniWM bundles Default and its generic APIs; these styles are installed separately. Install and choose a style from the gallery in **Settings > Styles & Widgets**.

Contributors can try a checkout style as described in [Trying a Style](../website/src/content/docs/developers/contributing.md#trying-a-style). Follow [TEMPLATE.md](TEMPLATE.md) for each style README.

```text
<name>/
├── style.toml          English metadata, plain MAJOR.MINOR.PATCH version and style API
├── README.md           Summary, previews, behaviour, controls and credits
├── previews/           Gallery images or GIFs, when available
├── strings/            Widget and option translations in <locale>.toml
├── widgets/            Luau widgets and components
├── lib/                Shared Luau modules for this style
├── themes/             Style-owned palettes
├── shaders/            Metal effects
└── fonts/              Font files and their notices
```

Every style has `style.toml` and `README.md`; the other folders are optional. Keep upstream notices in the style folder and font notices beside their fonts. Manifest text stays in English; widget translations fall back from the exact locale to the language, English and the app's own strings.
