package edu.practice.scheduler.model;
public class BatchWorkload extends Workload {
 public BatchWorkload(long id,int cpuCores,int memoryMb,int durationTicks,int releaseTick){
  super(id,cpuCores,memoryMb,durationTicks,releaseTick);
 }
 @Override public int urgencyAt(int nowTick){
  if(nowTick<0) throw new IllegalArgumentException("nowTick must not be negative");
  long age=Math.max(0L,(long)nowTick-getReleaseTick());
  return (int)Math.min(Integer.MAX_VALUE,100L+2L*age);
 }
 @Override public int latestStartTick(){return Integer.MAX_VALUE;}
}
