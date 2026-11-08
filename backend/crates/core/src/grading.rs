//! Leg grading and entry settlement. Values and lines are scaled integers
//! (tenths), so 265.5 is stored as 2655.

use crate::payout;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Over,
    Under,
}

impl Side {
    pub fn parse(s: &str) -> Option<Side> {
        match s {
            "over" => Some(Side::Over),
            "under" => Some(Side::Under),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Side::Over => "over",
            Side::Under => "under",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LegResult {
    Win,
    Loss,
    Push,
    Void,
}

impl LegResult {
    pub fn as_str(self) -> &'static str {
        match self {
            LegResult::Win => "win",
            LegResult::Loss => "loss",
            LegResult::Push => "push",
            LegResult::Void => "void",
        }
    }
    pub fn parse(s: &str) -> Option<LegResult> {
        match s {
            "win" => Some(LegResult::Win),
            "loss" => Some(LegResult::Loss),
            "push" => Some(LegResult::Push),
            "void" => Some(LegResult::Void),
            _ => None,
        }
    }
}

pub fn grade_leg(side: Side, line_x10: i32, value_x10: i32) -> LegResult {
    use std::cmp::Ordering::*;
    match (value_x10.cmp(&line_x10), side) {
        (Equal, _) => LegResult::Push,
        (Greater, Side::Over) | (Less, Side::Under) => LegResult::Win,
        _ => LegResult::Loss,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryStatus {
    Won,
    Lost,
    /// Stake refunded because the entry could not be graded as placed.
    Void,
}

impl EntryStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            EntryStatus::Won => "won",
            EntryStatus::Lost => "lost",
            EntryStatus::Void => "void",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settlement {
    pub status: EntryStatus,
    /// Gross coins credited back to the wallet.
    pub credit: i64,
}

pub fn settle_single(rule_version: i32, stake: i64, leg: LegResult) -> Settlement {
    match leg {
        LegResult::Win => Settlement { status: EntryStatus::Won, credit: payout::single_return(rule_version, stake) },
        LegResult::Loss => Settlement { status: EntryStatus::Lost, credit: 0 },
        LegResult::Push | LegResult::Void => Settlement { status: EntryStatus::Void, credit: stake },
    }
}

/// Pushed or voided legs drop out and the parlay pays at the reduced leg
/// count. Fewer than two live legs refunds the stake.
pub fn settle_parlay(rule_version: i32, stake: i64, legs: &[LegResult]) -> Settlement {
    if legs.iter().any(|l| *l == LegResult::Loss) {
        return Settlement { status: EntryStatus::Lost, credit: 0 };
    }
    let live = legs.iter().filter(|l| **l == LegResult::Win).count();
    match payout::parlay_return(rule_version, stake, live) {
        Some(credit) => Settlement { status: EntryStatus::Won, credit },
        None => Settlement { status: EntryStatus::Void, credit: stake },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use LegResult::*;

    #[test]
    fn grades_legs() {
        assert_eq!(grade_leg(Side::Over, 2655, 2840), Win);
        assert_eq!(grade_leg(Side::Under, 2655, 2840), Loss);
        assert_eq!(grade_leg(Side::Under, 2655, 2410), Win);
        assert_eq!(grade_leg(Side::Over, 270, 270), Push);
    }

    #[test]
    fn settles_singles() {
        assert_eq!(settle_single(1, 100, Win).credit, 225);
        assert_eq!(settle_single(1, 100, Loss).credit, 0);
        assert_eq!(settle_single(1, 100, Push), Settlement { status: EntryStatus::Void, credit: 100 });
        assert_eq!(settle_single(1, 0, Win).credit, 25);
    }

    #[test]
    fn settles_parlays() {
        assert_eq!(settle_parlay(1, 100, &[Win, Win, Win]).credit, 575);
        assert_eq!(settle_parlay(1, 100, &[Win, Loss, Win]).credit, 0);
        assert_eq!(settle_parlay(1, 100, &[Win, Push, Win]).credit, 350);
        assert_eq!(settle_parlay(1, 100, &[Win, Void]), Settlement { status: EntryStatus::Void, credit: 100 });
        assert_eq!(settle_parlay(1, 0, &[Win; 5]).credit, 125);
    }
}
