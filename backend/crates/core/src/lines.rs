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

/// Stats graded on the game score rather than a player's box score.
pub const GAME_STATS: [&str; 3] = ["moneyline", "spread", "total"];

pub fn is_game_stat(stat_key: &str) -> bool {
    GAME_STATS.contains(&stat_key)
}

/// Moneyline is "home margin over 0.5": Over means the home team wins.
pub const MONEYLINE_X10: i32 = 5;

fn half_point(x: f64) -> i32 {
    (x.floor() * 10.0 + 5.0) as i32
}

#[derive(Debug, PartialEq, Eq)]
pub struct GameLines {
    /// Home margin to beat, in tenths. 35 means the home team is -3.5.
    pub spread_x10: i32,
    pub total_x10: i32,
}

/// Lines for a game from each team's recent finals, newest first, as
/// (margin for that team, combined points).
pub fn game_lines(league: &str, home: &[(i32, i32)], away: &[(i32, i32)]) -> Option<GameLines> {
    if home.len() < MIN_GAMES || away.len() < MIN_GAMES {
        return None;
    }
    let avg = |v: &[(i32, i32)], f: fn(&(i32, i32)) -> i32| {
        let take = &v[..v.len().min(FORM_GAMES)];
        take.iter().map(|x| f(x) as f64).sum::<f64>() / take.len() as f64
    };
    let home_edge = if league == "nba" { 2.0 } else { 1.5 };
    let margin = (avg(home, |x| x.0) - avg(away, |x| x.0)) / 2.0 + home_edge;
    let total = (avg(home, |x| x.1) + avg(away, |x| x.1)) / 2.0;
    Some(GameLines { spread_x10: half_point(margin), total_x10: half_point(total) })
}

fn signed(v: f64) -> String {
    if v > 0.0 {
        format!("+{v:.1}")
    } else {
        format!("{v:.1}")
    }
}

/// What a right (Over) and left (Under) swipe mean on a game market.
pub fn side_labels(stat_key: &str, line_x10: i32, home: &str, away: &str) -> Option<(String, String)> {
    let line = line_x10 as f64 / 10.0;
    match stat_key {
        "moneyline" => Some((home.to_string(), away.to_string())),
        "spread" => Some((format!("{home} {}", signed(-line)), format!("{away} {}", signed(line)))),
        "total" => Some((format!("Over {line:.1}"), format!("Under {line:.1}"))),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn game_lines_from_recent_results() {
        let home = [(7, 41), (3, 47), (-2, 44)];
        let away = [(-3, 40), (1, 45), (-4, 50)];
        let l = game_lines("nfl", &home, &away).unwrap();
        // Home +2.67, away -2: (2.67 + 2) / 2 + 1.5 = 3.83 -> 3.5; totals 44 and 45 -> 44.5.
        assert_eq!(l, GameLines { spread_x10: 35, total_x10: 445 });
        assert_eq!(game_lines("nba", &home[..2], &away), None);
    }

    #[test]
    fn game_side_labels() {
        assert_eq!(side_labels("spread", 35, "BUF", "MIA"), Some(("BUF -3.5".into(), "MIA +3.5".into())));
        assert_eq!(side_labels("spread", -25, "BUF", "MIA"), Some(("BUF +2.5".into(), "MIA -2.5".into())));
        assert_eq!(side_labels("moneyline", MONEYLINE_X10, "BUF", "MIA"), Some(("BUF".into(), "MIA".into())));
        assert_eq!(side_labels("total", 445, "BUF", "MIA"), Some(("Over 44.5".into(), "Under 44.5".into())));
        assert_eq!(side_labels("pts", 245, "BUF", "MIA"), None);
    }

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
