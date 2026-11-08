//! Pure, versioned game rules. No I/O lives here so that the API, the worker
//! and tests all compute identical results from identical inputs.

pub mod colorway;
pub mod contest;
pub mod grading;
pub mod lines;
pub mod mastery;
pub mod payout;

pub use grading::{LegResult, Side};
