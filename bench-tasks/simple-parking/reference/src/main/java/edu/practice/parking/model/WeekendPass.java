package edu.practice.parking.model;
public class WeekendPass extends ParkingPass {
 private final int flatCents;
 public WeekendPass(long id,String registration,int flatCents){super(id,registration);this.flatCents=flatCents;}
 public int getFlatCents(){return flatCents;}
 public int priceCents(int stayMinutes){
  if(stayMinutes<=0) throw new IllegalArgumentException("stayMinutes must be positive");
  if(stayMinutes<=480) return flatCents;
  long extraHours=(stayMinutes-480L+59)/60;
  return Math.toIntExact(flatCents+150L*extraHours);
 }
}
