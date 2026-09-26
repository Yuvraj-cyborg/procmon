//! Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
//!
//! Items are laid out in rows along the shorter side of the remaining space,
//! greedily adding items to a row while doing so improves the worst aspect
//! ratio in that row. This keeps tiles close to square, which makes sizes easy
//! to compare by eye.

/// An axis-aligned rectangle in arbitrary units.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }

    pub fn area(&self) -> f32 {
        self.w * self.h
    }

    /// Shrinks every side by `amount`, never producing negative sizes.
    pub fn inset(&self, amount: f32) -> Self {
        let dx = amount.min(self.w / 2.0);
        let dy = amount.min(self.h / 2.0);
        Self::new(
            self.x + dx,
            self.y + dy,
            self.w - 2.0 * dx,
            self.h - 2.0 * dy,
        )
    }
}

/// Lays out `weights` inside `bounds`. Returns one rectangle per weight, in
/// input order. Weights should be sorted descending for best results; zero or
/// negative weights get an empty rectangle.
pub fn squarify(weights: &[f64], bounds: Rect) -> Vec<Rect> {
    let mut out = vec![Rect::new(bounds.x, bounds.y, 0.0, 0.0); weights.len()];
    let total: f64 = weights.iter().filter(|w| **w > 0.0).sum();
    if total <= 0.0 || bounds.area() <= 0.0 {
        return out;
    }

    // Scale weights to areas in the target coordinate space.
    let scale = f64::from(bounds.area()) / total;
    let items: Vec<(usize, f64)> = weights
        .iter()
        .enumerate()
        .filter(|(_, w)| **w > 0.0)
        .map(|(i, w)| (i, w * scale))
        .collect();

    let mut free = bounds;
    let mut start = 0;
    while start < items.len() {
        let side = f64::from(free.w.min(free.h));
        let mut end = start + 1;
        let mut row_sum = items[start].1;
        let mut best = worst_ratio(&items[start..end], row_sum, side);
        while end < items.len() {
            let candidate_sum = row_sum + items[end].1;
            let candidate = worst_ratio(&items[start..=end], candidate_sum, side);
            if candidate > best {
                break;
            }
            best = candidate;
            row_sum = candidate_sum;
            end += 1;
        }
        free = place_row(&items[start..end], row_sum, free, &mut out);
        start = end;
    }
    out
}

/// Worst (largest) aspect ratio of a row laid along a side of length `side`.
fn worst_ratio(row: &[(usize, f64)], sum: f64, side: f64) -> f64 {
    let (min, max) = row
        .iter()
        .fold((f64::INFINITY, 0.0_f64), |(lo, hi), (_, a)| {
            (lo.min(*a), hi.max(*a))
        });
    let side2 = side * side;
    let sum2 = sum * sum;
    (side2 * max / sum2).max(sum2 / (side2 * min))
}

/// Places a row along the shorter side of `free` and returns the space left over.
fn place_row(row: &[(usize, f64)], sum: f64, free: Rect, out: &mut [Rect]) -> Rect {
    if free.w >= free.h {
        // Column on the left, items stacked top to bottom.
        let thickness = (sum / f64::from(free.h)) as f32;
        let mut y = free.y;
        for (ix, area) in row {
            let h = (*area / f64::from(thickness)) as f32;
            out[*ix] = Rect::new(free.x, y, thickness, h);
            y += h;
        }
        Rect::new(
            free.x + thickness,
            free.y,
            (free.w - thickness).max(0.0),
            free.h,
        )
    } else {
        // Row along the top, items left to right.
        let thickness = (sum / f64::from(free.w)) as f32;
        let mut x = free.x;
        for (ix, area) in row {
            let w = (*area / f64::from(thickness)) as f32;
            out[*ix] = Rect::new(x, free.y, w, thickness);
            x += w;
        }
        Rect::new(
            free.x,
            free.y + thickness,
            free.w,
            (free.h - thickness).max(0.0),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPS: f32 = 1e-3;

    fn within(r: &Rect, b: &Rect) -> bool {
        r.x >= b.x - EPS
            && r.y >= b.y - EPS
            && r.x + r.w <= b.x + b.w + EPS
            && r.y + r.h <= b.y + b.h + EPS
    }

    fn overlaps(a: &Rect, b: &Rect) -> bool {
        a.x + EPS < b.x + b.w
            && b.x + EPS < a.x + a.w
            && a.y + EPS < b.y + b.h
            && b.y + EPS < a.y + a.h
    }

    #[test]
    fn areas_are_proportional_and_fill_bounds() {
        let weights = [6.0, 6.0, 4.0, 3.0, 2.0, 2.0, 1.0];
        let bounds = Rect::new(0.0, 0.0, 6.0, 4.0);
        let rects = squarify(&weights, bounds);
        let total: f64 = weights.iter().sum();
        for (w, r) in weights.iter().zip(&rects) {
            let expected = (*w / total) as f32 * bounds.area();
            assert!((r.area() - expected).abs() < 1e-2, "{r:?} vs {expected}");
            assert!(within(r, &bounds));
        }
        let covered: f32 = rects.iter().map(Rect::area).sum();
        assert!((covered - bounds.area()).abs() < 1e-2);
    }

    #[test]
    fn rectangles_do_not_overlap() {
        let weights: Vec<f64> = (1..=40).rev().map(f64::from).collect();
        let rects = squarify(&weights, Rect::new(10.0, 20.0, 800.0, 300.0));
        for (i, a) in rects.iter().enumerate() {
            for b in &rects[i + 1..] {
                assert!(!overlaps(a, b), "{a:?} overlaps {b:?}");
            }
        }
    }

    #[test]
    fn classic_paper_example_is_reasonably_square() {
        let rects = squarify(
            &[6.0, 6.0, 4.0, 3.0, 2.0, 2.0, 1.0],
            Rect::new(0.0, 0.0, 6.0, 4.0),
        );
        for r in &rects {
            let ratio = (r.w / r.h).max(r.h / r.w);
            assert!(ratio < 3.0, "{r:?} has aspect ratio {ratio}");
        }
    }

    #[test]
    fn degenerate_inputs_are_empty() {
        assert!(squarify(&[], Rect::new(0.0, 0.0, 1.0, 1.0)).is_empty());
        let rects = squarify(&[0.0, 5.0], Rect::new(0.0, 0.0, 1.0, 1.0));
        assert_eq!(rects[0].area(), 0.0);
        assert!((rects[1].area() - 1.0).abs() < EPS);
        let rects = squarify(&[1.0], Rect::new(0.0, 0.0, 0.0, 5.0));
        assert_eq!(rects[0].area(), 0.0);
    }
}
