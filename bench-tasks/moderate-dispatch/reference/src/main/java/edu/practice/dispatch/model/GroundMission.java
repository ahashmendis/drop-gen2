package edu.practice.dispatch.model;
public class GroundMission extends DispatchMission {
 private final boolean medical;
 public GroundMission(long id,int distanceKm,int loadKg,boolean medical){super(id,distanceKm,loadKg);this.medical=medical;}
 public boolean isMedical(){return medical;}
 @Override public int energyUnits(){
  long e=2L*getDistanceKm()+5L*getLoadKg();
  return Math.toIntExact(e);
 }
 @Override public int priority(){ return medical?3:1; }
}
