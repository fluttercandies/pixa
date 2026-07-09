use crate::{image_metadata, RuntimeError, RuntimeResult};
use std::collections::HashMap;

const MAX_ANALYSIS_DECODE_PIXELS: u64 = 64 * 1024 * 1024;
const DEFAULT_PALETTE_COLORS: usize = 6;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImageAnalysis {
    pub width: u32,
    pub height: u32,
    pub average_argb: u32,
    pub dominant_argb: u32,
    pub palette_argb: Vec<u32>,
}

pub fn image_analysis(bytes: &[u8], max_sample_pixels: usize) -> RuntimeResult<ImageAnalysis> {
    let metadata = image_metadata(bytes)?;
    let decoded_pixels = u64::from(metadata.width) * u64::from(metadata.height);
    if decoded_pixels == 0 || decoded_pixels > MAX_ANALYSIS_DECODE_PIXELS {
        return Err(RuntimeError::new(
            "analysis",
            false,
            "image analysis input exceeds decoded pixel budget",
        ));
    }
    let decoded = image::load_from_memory(bytes).map_err(|error| {
        RuntimeError::new(
            "analysis",
            false,
            format!("failed to decode image for analysis: {error}"),
        )
    })?;
    let sample_limit = max_sample_pixels.clamp(1, 4096);
    let sampled = sampled_rgba(decoded, sample_limit);
    let mut red_sum = 0_u64;
    let mut green_sum = 0_u64;
    let mut blue_sum = 0_u64;
    let mut alpha_sum = 0_u64;
    let mut counts = HashMap::<u32, (u32, usize)>::new();
    let mut index = 0_usize;
    for pixel in sampled.pixels() {
        let [red, green, blue, alpha] = pixel.0;
        red_sum += u64::from(red);
        green_sum += u64::from(green);
        blue_sum += u64::from(blue);
        alpha_sum += u64::from(alpha);
        let argb = argb(alpha, red, green, blue);
        counts
            .entry(argb)
            .and_modify(|(count, _)| *count += 1)
            .or_insert((1, index));
        index += 1;
    }
    if index == 0 {
        return Err(RuntimeError::new(
            "analysis",
            false,
            "image analysis sample is empty",
        ));
    }
    let pixels = index as u64;
    let average_argb = argb(
        (alpha_sum / pixels) as u8,
        (red_sum / pixels) as u8,
        (green_sum / pixels) as u8,
        (blue_sum / pixels) as u8,
    );
    let mut palette = counts
        .into_iter()
        .map(|(color, (count, first_index))| (color, count, first_index))
        .collect::<Vec<_>>();
    palette.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    let palette_argb = palette
        .iter()
        .take(DEFAULT_PALETTE_COLORS)
        .map(|(color, _, _)| *color)
        .collect::<Vec<_>>();
    let dominant_argb = palette_argb.first().copied().unwrap_or(average_argb);
    Ok(ImageAnalysis {
        width: metadata.width,
        height: metadata.height,
        average_argb,
        dominant_argb,
        palette_argb,
    })
}

fn sampled_rgba(image: image::DynamicImage, max_sample_pixels: usize) -> image::RgbaImage {
    let width = image.width();
    let height = image.height();
    if u64::from(width) * u64::from(height) <= max_sample_pixels as u64 {
        return image.to_rgba8();
    }
    let scale = (max_sample_pixels as f64 / (f64::from(width) * f64::from(height))).sqrt();
    let sample_width = ((f64::from(width) * scale).floor() as u32).max(1);
    let sample_height = ((f64::from(height) * scale).floor() as u32).max(1);
    image.thumbnail(sample_width, sample_height).to_rgba8()
}

fn argb(alpha: u8, red: u8, green: u8, blue: u8) -> u32 {
    (u32::from(alpha) << 24) | (u32::from(red) << 16) | (u32::from(green) << 8) | u32::from(blue)
}
