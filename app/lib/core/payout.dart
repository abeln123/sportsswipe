/// Display-only mirror of the server's rule_version 1 payout. The server's
/// receipt is authoritative.
const singleBonus = 25;
const legBonus = 25;

int singleReturn(int stake) => 2 * stake + singleBonus;

int parlayMultiplier(int legs) => switch (legs) { 2 => 3, 3 => 5, 4 => 8, 5 => 12, _ => 0 };

int parlayReturn(int stake, int legs) => parlayMultiplier(legs) * stake + legBonus * legs;
