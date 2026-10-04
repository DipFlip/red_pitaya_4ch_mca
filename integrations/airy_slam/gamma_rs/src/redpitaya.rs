//! Versioned MCA batches; raw words retain integer CFD time and detector ID.
use anyhow::{Result, bail};

pub struct Batch {
    pub start_s: f64,
    pub end_s: f64,
    pub live_s: f64,
    pub events: Vec<f64>,
    pub words: Vec<[u32; 9]>,
    pub epoch_ns: i64,
}

pub fn parse(data: &[u8]) -> Result<Batch> {
    if data.len() < 48 { bail!("invalid Red Pitaya batch header"); }
    let version = match &data[..8] { b"RPMROS01" => 1, b"RPMROS02" => 2, _ => bail!("invalid Red Pitaya batch version") };
    let (header, size) = if version == 1 { (48,32) } else { (88,36) };
    if data.len()<header { bail!("truncated Red Pitaya batch header"); }
    let u64_at = |i| u64::from_le_bytes(data[i..i+8].try_into().unwrap());
    let u32_at = |i| u32::from_le_bytes(data[i..i+4].try_into().unwrap());
    let (end, start) = (u64_at(8), u64_at(16));
    let epoch = i64::from_le_bytes(data[24..32].try_into().unwrap());
    let live = u64_at(32);
    let (count, mask) = (u32_at(40) as usize, u32_at(44));
    if end <= start || live > end - start || count > (data.len() - header) / size || data.len() != header + count * size {
        bail!("invalid Red Pitaya batch exposure or length");
    }
    let active = if version==2 { u32_at(48) } else { 1 };
    if active==0 || active & !15 != 0 || (version==2 && u32_at(52)!=0) { bail!("invalid active channels"); }
    let stamp = |tick: u64, frac: u32| epoch as f64 * 1e-9 + (tick as f64 + frac as f64 / 65536.0) * 8e-9;
    let mut words = Vec::new();
    for record in data[header..].chunks_exact(size) {
        let mut w=[0u32;9];
        for (i,v) in record.chunks_exact(4).enumerate(){ w[i]=u32::from_le_bytes(v.try_into().unwrap()); }
        if version==1 {w[8]=1;}
        if !(1..=4).contains(&w[8]) || active & (1<<(w[8]-1))==0 { bail!("event from inactive channel"); }
        let tick = u64::from(w[0]) | (u64::from(w[1])<<32);
        if tick > end { bail!("Red Pitaya event is beyond batch boundary"); }
        if (w[2] >> 16) & mask == 0 { words.push(w); }
    }
    // FIFO polling order is not timestamp order across independent detectors.
    words.sort_by_key(|w| (u64::from(w[0]) | (u64::from(w[1])<<32),w[2]&65535));
    let events=words.iter().map(|w|stamp(u64::from(w[0])|(u64::from(w[1])<<32),w[2]&65535)).collect();
    Ok(Batch { start_s: stamp(start, 0), end_s: stamp(end, 0), live_s: live as f64 * 8e-9, events,words,epoch_ns:epoch })
}

#[cfg(test)]
mod tests {
 use super::*;
 fn packet(flags:u16)->Vec<u8>{
  let mut p=b"RPMROS01".to_vec();
  for x in [12500000u64,0,0,12000000]{p.extend(x.to_le_bytes());}
  for x in [1u32,31]{p.extend(x.to_le_bytes());}
  for x in [6250000u32,0,(u32::from(flags)<<16)|32768,100,500,0,1,(3125<<16)|250]{p.extend(x.to_le_bytes());}
  p
 }
 #[test] fn exact_fpga_time_and_exposure(){
  let b=parse(&packet(0)).unwrap();assert!((b.end_s-0.1).abs()<1e-12);
  assert!((b.live_s-0.096).abs()<1e-12);assert!((b.events[0]-0.050000004).abs()<1e-12);
  assert_eq!(b.words[0][8],1);assert!(parse(&packet(4)).unwrap().events.is_empty());
 }
 #[test] fn rejects_truncated_and_invalid_exposure(){
  let p=packet(0);for n in 0..p.len(){assert!(parse(&p[..n]).is_err());}
  let mut p=packet(0);p[32..40].copy_from_slice(&12500001u64.to_le_bytes());assert!(parse(&p).is_err());
 }
 #[test] fn four_channel_ids_sorting_and_raw_fraction_survive(){
  let old=packet(0);let mut p=old[..48].to_vec();p[..8].copy_from_slice(b"RPMROS02");p[40..44].copy_from_slice(&2u32.to_le_bytes());
  for x in [9u32,0]{p.extend(x.to_le_bytes());}for x in [12000000u64,0,0,11900000]{p.extend(x.to_le_bytes());}
  p.extend(&old[48..]);p.extend(4u32.to_le_bytes());let mut early=old[48..].to_vec();early[..4].copy_from_slice(&100u32.to_le_bytes());
  p.extend(early);p.extend(1u32.to_le_bytes());let b=parse(&p).unwrap();assert_eq!(b.words[0][8],1);assert_eq!(b.words[1][8],4);
  assert_eq!(b.words[1][2],32768);assert!(b.events[0]<b.events[1]);
  p[48..52].copy_from_slice(&1u32.to_le_bytes());assert!(parse(&p).is_err());
 }
}
