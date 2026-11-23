package edu.practice.dispatch.service;
import edu.practice.dispatch.model.*;import edu.practice.dispatch.dto.*;import edu.practice.dispatch.repo.*;import edu.practice.dispatch.error.*;
import org.springframework.stereotype.Service;import java.util.*;
@Service public class DispatchService {
 private final MissionRepository repo;
 public DispatchService(MissionRepository repo){this.repo=repo;}
 public Collection<DispatchMission> all(){return repo.all();}
 public int energy(long id){
  DispatchMission m=repo.find(id);
  if(m==null) throw new MissionNotFoundException(id);
  return m.energyUnits();
 }
 public DispatchMission addAir(NewAirMission r){
  if(r.id()<=0) throw new IllegalArgumentException("id must be positive");
  if(r.distanceKm()<=0||r.distanceKm()>10000) throw new IllegalArgumentException("distanceKm must be 1-10000");
  if(r.loadKg()<0||r.loadKg()>10000) throw new IllegalArgumentException("loadKg must be 0-10000");
  if(r.windPenalty()<0||r.windPenalty()>10000) throw new IllegalArgumentException("windPenalty must be 0-10000");
  if(repo.exists(r.id())) throw new IllegalArgumentException("duplicate id");
  AirMission m=new AirMission(r.id(),r.distanceKm(),r.loadKg(),r.windPenalty(),r.critical());
  m.energyUnits();
  repo.save(m);
  return m;
 }
 public DispatchPlan plan(int capacity,boolean urgentOnly){
  if(capacity<=0) throw new IllegalArgumentException("capacity must be positive");
  List<DispatchMission> list=new ArrayList<>();
  for(DispatchMission m:repo.all()) if(!urgentOnly||m.priority()>=3) list.add(m);
  list.sort(Comparator.comparingInt(DispatchMission::priority).reversed()
    .thenComparingInt(DispatchMission::energyUnits).thenComparingLong(DispatchMission::getId));
  int remaining=capacity;
  List<PlanLine> selected=new ArrayList<>();List<Long> skipped=new ArrayList<>();
  for(DispatchMission m:list){
   int e=m.energyUnits();
   if(e<=remaining){remaining-=e;selected.add(new PlanLine(m.getId(),m.getClass().getSimpleName(),m.priority(),e));}
   else skipped.add(m.getId());
  }
  return new DispatchPlan(capacity,capacity-remaining,remaining,selected,skipped);
 }
}
