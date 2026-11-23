package edu.practice.parking.model;
public class HourlyPass extends ParkingPass {
 private final int rateCents;
 public HourlyPass(long id,String registration,int rateCents){super(id,registration);this.rateCents=rateCents;}
 public int getRateCents(){return rateCents;}
 public int priceCents(int stayMinutes){
  if(stayMinutes<0) throw new IllegalArgumentException("stayMinutes must not be negative");
  long hours=Math.max(1,(stayMinutes+59)/60);
  long total=hours*rateCents;
  if(total>Integer.MAX_VALUE) throw new IllegalArgumentException("price too large");
  return (int)total;
 }
}
