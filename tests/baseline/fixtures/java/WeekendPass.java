package edu.practice.parking.model;
public class WeekendPass extends ParkingPass {
 private final int flatCents;
 public WeekendPass(long id,String registration,int flatCents){super(id,registration);this.flatCents=flatCents;}
 public int getFlatCents(){return flatCents;}
 public int priceCents(int stayMinutes){
  if(stayMinutes<0) throw new IllegalArgumentException("stayMinutes must not be negative");
  return flatCents;
 }
}
