//! Line generation. ESPN publishes no player props, so lines are derived from
//! recent form: the average of the last `n` games, placed on the half point
//! so a push is impossible.

pub const FORM_GAMES: usize = 5;
pub const MIN_GAMES: usize = 3;

/// `recent_x10` is newest first. Returns a line in tenths ending in .5.
pub fn generate_line(recent_x10: &[i32]) -> Option<i32> {
    let take: Vec<i32> = recent_x10.iter().take(FORM_GAMES).copied().collect();
    if take.len() < MIN_GAMES {
        return None;
    }
    let avg = take.iter().map(|v| *v as f64).sum::<f64>() / take.len() as f64 / 10.0;
    // A stat with almost no production makes a meaningless card.
    if avg < 0.5 {
        return None;
    }
    Some((avg.floor() * 10.0 + 5.0) as i32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_point_lines() {
        assert_eq!(generate_line(&[310, 260, 340, 290, 240]), Some(285));
        assert_eq!(generate_line(&[2800, 2410, 3120, 2560, 2740]), Some(2725));
        assert_eq!(generate_line(&[10, 20]), None);
        assert_eq!(generate_line(&[0, 0, 0]), None);
        assert_eq!(generate_line(&[10, 0, 0]), None);
        assert_eq!(generate_line(&[10, 10, 10]), Some(15));
    }
}
