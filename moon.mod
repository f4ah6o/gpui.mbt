name = "f4ah6o/gpui"

version = "0.3.0"

readme = "README.mbt.md"

repository = "https://github.com/gpui-mbt/gpui.mbt"

license = "Apache-2.0"

source = "."

description = "An independent MoonBit implementation of the GPUI programming model."

options(
  "--moonbit-unstable-prebuild": "script/macos_text_prebuild.py",
)
