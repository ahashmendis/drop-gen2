package edu.practice.scheduler.model;
public class DeadlineWorkload extends Workload {
 private final int deadlineTick;
 public DeadlineWorkload(long id,int cpuCores,int memoryMb,int durationTicks,int releaseTick,int deadlineTick){
  super(id,cpuCores,memoryMb,durationTicks,releaseTick);this.deadlineTick=deadlineTick;
 }
 public int getDeadlineTick(){return deadlineTick;}
 @Override public int urgencyAt(int nowTick){
  if(nowTick<0) throw new IllegalArgumentException("nowTick must not be negative");
  long slack=Math.max(0L,(long)deadlineTick-nowTick-getDurationTicks());
  return (int)Math.max(Integer.MIN_VALUE,1000L-5L*slack);
 }
 @Override public int latestStartTick(){return deadlineTick-getDurationTicks();}
}
