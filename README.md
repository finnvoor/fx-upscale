# ↕️ fx-upscale
Metal-powered video upscaling

<p align="center">
<img src="https://github.com/Finnvoor/fx-upscale/assets/8284016/b3613348-a553-43b6-a607-fd35f33d99d6" width="800" />
  <img src="https://github.com/finnvoor/fx-upscale/assets/8284016/7ae867c2-caef-43d8-8fe3-7048c55f55bd" width="800" />
</p>

> [!TIP]
> Looking for an app-based version of `fx-upscale`? Pre-order [_Unsqueeze_](https://apps.apple.com/app/apple-store/id6475134617?pt=120542042&ct=github&mt=8) today! 🔥

## Usage
```
USAGE: fx-upscale <url> [--width <width>] [--height <height>]

ARGUMENTS:
  <url>                   The video file to upscale

OPTIONS:
  -w, --width <width>     The output file width
  -h, --height <height>   The output file height
  -h, --help              Show help information.
```
- If width and height are specified, they will be used for the output dimensions
- If only 1 of width or height is specified, the other will be inferred proportionally
- If neither width nor height is specified, the video will be upscaled by 2x

> [!NOTE]
> When upscaling videos to >4k, `.mp4` files will be converted to `.mov` and `h264` or `hevc` codecs will be re-encoded as `proRes422`.  This is due to the fact that macOS struggles to play back >4k video `h264` and `hevc` files, and `h264` and `hevc` codecs only support up to ~8k.  If you have a use case for creating >4k `h264`/`hevc` `.mp4`'s, please open an issue.

## Installation
### Homebrew
```bash
brew install finnvoor/tools/fx-upscale
```

### Mint
```bash
mint install finnvoor/fx-upscale
```

### Manual
Download the latest release from [releases](https://github.com/Finnvoor/MetalFXUpscale/releases).
