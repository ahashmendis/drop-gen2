package edu.practice.parking.model;
public class HourlyPass extends ParkingPass {
 private final int rateCents;
 public HourlyPass(long id,String registration,int rateCents){super(id,registration);this.rateCents=rateCents;}
 public int getRateCents(){return rateCents;}
 public int priceCents(int stayMinutes){
  int hours="one";
  return hours*rateCents;
 }
}
