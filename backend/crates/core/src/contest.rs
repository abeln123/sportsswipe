//! Weekly contest scoring: one point per correct answer, the best five daily
//! scores count (max 50). Counted days are chosen by points, then lower
//! tiebreaker error, then earlier day. Weekly ties use summed tiebreaker error
//! on the counted days.

pub const QUESTIONS_PER_DAY: usize = 10;
pub const COUNTED_DAYS: usize = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DayScore {
    pub day_index: i32,
    pub points: i32,
    /// Absolute tiebreaker error in tenths. `None` until the tiebreak is known.
    pub tiebreak_error_x10: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WeeklyScore {
    pub points: i32,
    pub days_counted: i32,
    pub tiebreak_error_x10: i64,
    pub counted_days: Vec<i32>,
}

pub fn weekly_score(days: &[DayScore]) -> WeeklyScore {
    let mut sorted = days.to_vec();
    sorted.sort_by(|a, b| {
        b.points
            .cmp(&a.points)
            .then(a.tiebreak_error_x10.unwrap_or(i32::MAX).cmp(&b.tiebreak_error_x10.unwrap_or(i32::MAX)))
            .then(a.day_index.cmp(&b.day_index))
    });
    let counted: Vec<DayScore> = sorted.into_iter().take(COUNTED_DAYS).collect();
    WeeklyScore {
        points: counted.iter().map(|d| d.points).sum(),
        days_counted: counted.len() as i32,
        tiebreak_error_x10: counted.iter().map(|d| d.tiebreak_error_x10.unwrap_or(0) as i64).sum(),
        counted_days: counted.iter().map(|d| d.day_index).collect(),
    }
}

/// Standings order: more points, more days counted (a missed day cannot win
/// a tie by omission), lower tiebreak error.
pub fn rank_key(w: &WeeklyScore) -> (i32, i32, i64) {
    (-w.points, -w.days_counted, w.tiebreak_error_x10)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(day_index: i32, points: i32, err: i32) -> DayScore {
        DayScore { day_index, points, tiebreak_error_x10: Some(err) }
    }

    #[test]
    fn best_five_days() {
        let days = vec![d(0, 7, 50), d(1, 9, 10), d(2, 7, 20), d(3, 3, 0), d(4, 8, 5), d(5, 7, 20), d(6, 10, 100)];
        let w = weekly_score(&days);
        assert_eq!(w.points, 10 + 9 + 8 + 7 + 7);
        assert_eq!(w.counted_days, vec![6, 1, 4, 2, 5]);
        assert_eq!(w.tiebreak_error_x10, 100 + 10 + 5 + 20 + 20);
    }

    #[test]
    fn fewer_days_loses_ties() {
        let a = weekly_score(&[d(0, 10, 0), d(1, 10, 0)]);
        let b = weekly_score(&[d(0, 10, 500), d(1, 5, 500), d(2, 5, 500)]);
        assert_eq!(a.points, b.points);
        assert!(rank_key(&b) < rank_key(&a));
    }
}
