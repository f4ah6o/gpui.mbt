///|
/// A byte-based color channel outside the inclusive [0, 255] range.
pub enum ColorError {
  ChannelOutOfRange
} derive(Eq)

///|
pub extend ColorError with Eq::{not_equal, equal}

///|
/// An sRGB RGBA color with 8-bit channels.
pub struct Color {
  red : Int
  green : Int
  blue : Int
  alpha : Int
} derive(Eq)

///|
pub extend Color with Eq::{not_equal, equal}

///|
/// Construct an sRGB color from integer channels in [0, 255].
pub fn Color::rgba(
  red : Int,
  green : Int,
  blue : Int,
  alpha : Int,
) -> Result[Color, ColorError] {
  if !channel_is_valid(red) ||
    !channel_is_valid(green) ||
    !channel_is_valid(blue) ||
    !channel_is_valid(alpha) {
    Err(ChannelOutOfRange)
  } else {
    Ok({ red, green, blue, alpha, })
  }
}

///|
fn channel_is_valid(value : Int) -> Bool {
  value >= 0 && value <= 255
}

///|
pub fn Color::red(self : Color) -> Int {
  self.red
}

///|
pub fn Color::green(self : Color) -> Int {
  self.green
}

///|
pub fn Color::blue(self : Color) -> Int {
  self.blue
}

///|
pub fn Color::alpha(self : Color) -> Int {
  self.alpha
}

///|
pub fn Color::is_opaque(self : Color) -> Bool {
  self.alpha == 255
}
