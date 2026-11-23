package edu.practice.scheduler.service;
import edu.practice.scheduler.model.*;import edu.practice.scheduler.dto.*;import edu.practice.scheduler.repo.*;import edu.practice.scheduler.error.*;
import org.springframework.stereotype.Service;import java.util.*;
@Service public class SchedulerService {
 private final WorkloadRepository repo;
 private final List<Reservation> confirmed=new ArrayList<>();
 private final Map<String,CommitRequest> runRequests=new HashMap<>();
 private final Map<String,SchedulePlan> runPlans=new HashMap<>();
 public SchedulerService(WorkloadRepository repo){this.repo=repo;}
 public Collection<Workload> all(){return repo.all();}
 public int urgency(long id,int nowTick){
  Workload w=repo.find(id);
  if(w==null) throw new WorkloadNotFoundException(id);
  return w.urgencyAt(nowTick);
 }
 public List<Workload> ranked(int nowTick){
  if(nowTick<0) throw new IllegalArgumentException("nowTick must not be negative");
  List<Workload> list=new ArrayList<>(repo.all());
  list.sort(Comparator.comparingInt((Workload w)->w.urgencyAt(nowTick)).reversed().thenComparingLong(Workload::getId));
  return list;
 }
 private void validate(PlanRequest r){
  if(r.nowTick()<0||r.nowTick()>1_000_000) throw new IllegalArgumentException("nowTick out of range");
  if(r.horizon()<1||r.horizon()>24) throw new IllegalArgumentException("horizon out of range");
  if(r.cpuCapacity()<1||r.cpuCapacity()>64) throw new IllegalArgumentException("cpuCapacity out of range");
  if(r.memoryCapacity()<1||r.memoryCapacity()>1_000_000) throw new IllegalArgumentException("memoryCapacity out of range");
 }
 private SchedulePlan plan(PlanRequest r){
  Map<Integer,int[]> usage=new HashMap<>();
  for(Reservation c:confirmed) for(int t=c.startTick();t<c.endTickExclusive();t++) add(usage,t,c.cpuCores(),c.memoryMb());
  int end=r.nowTick()+r.horizon();
  List<Reservation> selected=new ArrayList<>();List<Rejection> rejected=new ArrayList<>();
  for(Workload w:ranked(r.nowTick())){
   if(w.getCpuCores()>r.cpuCapacity()||w.getMemoryMb()>r.memoryCapacity()){rejected.add(new Rejection(w.getId(),"EXCEEDS_CAPACITY"));continue;}
   int earliest=Math.max(r.nowTick(),w.getReleaseTick());
   int windowLatest=end-w.getDurationTicks();
   if(earliest>windowLatest){rejected.add(new Rejection(w.getId(),"RELEASE_OUTSIDE_WINDOW"));continue;}
   int latest=Math.min(windowLatest,w.latestStartTick());
   if(earliest>latest){rejected.add(new Rejection(w.getId(),"DEADLINE"));continue;}
   Integer start=null;
   for(int s=earliest;s<=latest&&start==null;s++){
    boolean fits=true;
    for(int t=s;t<s+w.getDurationTicks()&&fits;t++){
     int[] u=usage.getOrDefault(t,new int[2]);
     if(u[0]+w.getCpuCores()>r.cpuCapacity()||u[1]+w.getMemoryMb()>r.memoryCapacity()) fits=false;
    }
    if(fits) start=s;
   }
   if(start==null){rejected.add(new Rejection(w.getId(),"NO_SLOT"));continue;}
   for(int t=start;t<start+w.getDurationTicks();t++) add(usage,t,w.getCpuCores(),w.getMemoryMb());
   selected.add(new Reservation(w.getId(),start,start+w.getDurationTicks(),w.getCpuCores(),w.getMemoryMb()));
  }
  return new SchedulePlan(r.nowTick(),r.horizon(),selected,rejected);
 }
 private static void add(Map<Integer,int[]> usage,int t,int cpu,int mem){int[] u=usage.computeIfAbsent(t,k->new int[2]);u[0]+=cpu;u[1]+=mem;}
 public synchronized List<Reservation> reservations(){
  List<Reservation> out=new ArrayList<>(confirmed);
  out.sort(Comparator.comparingInt(Reservation::startTick).thenComparingLong(Reservation::id));
  return out;
 }
 public synchronized SchedulePlan preview(PlanRequest request){validate(request);return plan(request);}
 public synchronized SchedulePlan commit(CommitRequest request){
  if(request.runKey()==null||request.runKey().isBlank()) throw new IllegalArgumentException("runKey required");
  validate(request.asPlanRequest());
  CommitRequest previous=runRequests.get(request.runKey());
  if(previous!=null){
   if(previous.equals(request)) return runPlans.get(request.runKey());
   throw new CommitConflictException(request.runKey());
  }
  SchedulePlan p=plan(request.asPlanRequest());
  confirmed.addAll(p.selected());runRequests.put(request.runKey(),request);runPlans.put(request.runKey(),p);
  return p;
 }
}
