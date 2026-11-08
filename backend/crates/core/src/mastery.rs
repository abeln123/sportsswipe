use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    None,
    Base,
    Bronze,
    Silver,
    Gold,
    Diamond,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::None => "none",
            Tier::Base => "base",
            Tier::Bronze => "bronze",
            Tier::Silver => "silver",
            Tier::Gold => "gold",
            Tier::Diamond => "diamond",
        }
    }
}

const THRESHOLDS: [(i64, Tier); 5] =
    [(400, Tier::Diamond), (200, Tier::Gold), (80, Tier::Silver), (20, Tier::Bronze), (1, Tier::Base)];

pub fn tier_for(correct: i64) -> Tier {
    THRESHOLDS.iter().find(|(n, _)| correct >= *n).map(|(_, t)| *t).unwrap_or(Tier::None)
}

/// The next tier and the cumulative count needed to reach it.
pub fn next_tier(correct: i64) -> Option<(Tier, i64)> {
    THRESHOLDS.iter().rev().find(|(n, _)| correct < *n).map(|(n, t)| (*t, *n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers() {
        assert_eq!(tier_for(0), Tier::None);
        assert_eq!(tier_for(1), Tier::Base);
        assert_eq!(tier_for(19), Tier::Base);
        assert_eq!(tier_for(20), Tier::Bronze);
        assert_eq!(tier_for(80), Tier::Silver);
        assert_eq!(tier_for(399), Tier::Gold);
        assert_eq!(tier_for(400), Tier::Diamond);
        assert_eq!(next_tier(0), Some((Tier::Base, 1)));
        assert_eq!(next_tier(1), Some((Tier::Bronze, 20)));
        assert_eq!(next_tier(400), None);
    }
}
