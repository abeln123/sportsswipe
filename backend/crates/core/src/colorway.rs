//! Jersey colorways derived from a team's primary and alternate colors.

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Colorway {
    pub base: String,
    pub trim: String,
    pub accent: String,
    pub number_fill: String,
    pub number_outline: String,
}

fn parse(hex: &str) -> Option<(u8, u8, u8)> {
    let h = hex.trim_start_matches('#');
    if h.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(h, 16).ok()?;
    Some(((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

fn fmt((r, g, b): (u8, u8, u8)) -> String {
    format!("{:02X}{:02X}{:02X}", r, g, b)
}

fn channel(c: u8) -> f64 {
    let c = c as f64 / 255.0;
    if c <= 0.03928 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

pub fn luminance(hex: &str) -> f64 {
    let (r, g, b) = parse(hex).unwrap_or((0, 0, 0));
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

pub fn contrast(a: &str, b: &str) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    let (hi, lo) = if la > lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

fn mix(a: &str, b: &str, t: f64) -> String {
    let (a, b) = (parse(a).unwrap_or((0, 0, 0)), parse(b).unwrap_or((255, 255, 255)));
    let m = |x: u8, y: u8| (x as f64 + (y as f64 - x as f64) * t).round() as u8;
    fmt((m(a.0, b.0), m(a.1, b.1), m(a.2, b.2)))
}

fn normalize(hex: &str, fallback: &str) -> String {
    parse(hex).map(fmt).unwrap_or_else(|| fallback.to_string())
}

pub fn derive(primary: &str, alternate: &str) -> Colorway {
    let base = normalize(primary, "1F2937");
    let mut trim = normalize(alternate, "FFFFFF");
    if contrast(&base, &trim) < 1.5 {
        trim = if luminance(&base) > 0.4 { "111111".into() } else { "FFFFFF".into() };
    }
    let accent = mix(&trim, "FFFFFF", 0.35);
    let white = "FFFFFF";
    let number_fill = if contrast(&base, white) >= contrast(&base, &trim) { white.to_string() } else { trim.clone() };
    let number_outline = if number_fill == trim { white.to_string() } else { trim.clone() };
    Colorway { base, trim, accent, number_fill, number_outline }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dark_base_gets_white_numbers() {
        let c = derive("00338d", "c60c30");
        assert_eq!(c.base, "00338D");
        assert_eq!(c.number_fill, "FFFFFF");
        assert_eq!(c.number_outline, "C60C30");
    }

    #[test]
    fn light_base_gets_trim_numbers() {
        let c = derive("ffc72c", "1d428a");
        assert_eq!(c.number_fill, "1D428A");
    }

    #[test]
    fn identical_colors_get_a_visible_trim() {
        let c = derive("000000", "000000");
        assert_eq!(c.trim, "FFFFFF");
    }
}
