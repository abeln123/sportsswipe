//! Coin returns. Every accepted entry snapshots `RULE_VERSION`, so later rule
//! changes never alter an existing receipt.

pub const RULE_VERSION: i32 = 1;
pub const CORRECT_CALL_BONUS: i64 = 25;
pub const MIN_PARLAY_LEGS: usize = 2;
pub const MAX_PARLAY_LEGS: usize = 5;
pub const MAX_STAKE: i64 = 100_000;
pub const SIGNUP_GRANT: i64 = 1_000;

/// Gross coins credited when a single pick is correct (includes the stake).
pub fn single_return(rule_version: i32, stake: i64) -> i64 {
    match rule_version {
        _ => 2 * stake + CORRECT_CALL_BONUS,
    }
}

pub fn parlay_multiplier(rule_version: i32, legs: usize) -> Option<i64> {
    match (rule_version, legs) {
        (_, 2) => Some(3),
        (_, 3) => Some(5),
        (_, 4) => Some(8),
        (_, 5) => Some(12),
        _ => None,
    }
}

/// Gross coins credited when every parlay leg is correct (includes the stake).
pub fn parlay_return(rule_version: i32, stake: i64, legs: usize) -> Option<i64> {
    parlay_multiplier(rule_version, legs).map(|m| m * stake + CORRECT_CALL_BONUS * legs as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_returns_match_the_screens() {
        assert_eq!(single_return(1, 0), 25);
        assert_eq!(single_return(1, 100), 225);
        assert_eq!(single_return(1, 179), 383);
    }

    #[test]
    fn parlay_returns_match_the_doc() {
        assert_eq!(parlay_return(1, 0, 5), Some(125));
        assert_eq!(parlay_return(1, 100, 3), Some(575));
        assert_eq!(parlay_return(1, 100, 2), Some(350));
        assert_eq!(parlay_return(1, 100, 1), None);
        assert_eq!(parlay_return(1, 100, 6), None);
    }
}
