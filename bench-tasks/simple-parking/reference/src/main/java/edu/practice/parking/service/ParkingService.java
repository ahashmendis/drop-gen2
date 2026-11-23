package edu.practice.parking.service;
import edu.practice.parking.model.*;import edu.practice.parking.dto.*;import edu.practice.parking.repo.*;import edu.practice.parking.error.*;
import org.springframework.stereotype.Service;import java.util.*;
@Service public class ParkingService {
 private final PassRepository repo;
 public ParkingService(PassRepository repo){this.repo=repo;}
 public Collection<ParkingPass> all(){return repo.all();}
 public Quote quote(long id,int minutes){
  if(minutes<=0) throw new IllegalArgumentException("minutes must be positive");
  ParkingPass p=repo.get(id);
  if(p==null) throw new PassNotFoundException(id);
  return toQuote(p,minutes);
 }
 public List<Quote> allQuotes(int minutes){
  if(minutes<=0) throw new IllegalArgumentException("minutes must be positive");
  List<Quote> quotes=new ArrayList<>();
  for(ParkingPass p:repo.all()) quotes.add(toQuote(p,minutes));
  quotes.sort(Comparator.comparingInt(Quote::priceCents).thenComparingLong(Quote::id));
  return quotes;
 }
 public ParkingPass addHourly(NewHourlyPass body){
  if(body.id()<=0) throw new IllegalArgumentException("id must be positive");
  if(body.registration()==null||body.registration().isBlank()) throw new IllegalArgumentException("registration required");
  if(body.rateCents()<=0) throw new IllegalArgumentException("rate must be positive");
  if(repo.contains(body.id())) throw new IllegalArgumentException("duplicate id");
  HourlyPass pass=new HourlyPass(body.id(),body.registration().trim(),body.rateCents());
  repo.save(pass);
  return pass;
 }
 private Quote toQuote(ParkingPass p,int minutes){
  return new Quote(p.getId(),p.getRegistration(),p.getClass().getSimpleName(),minutes,p.priceCents(minutes));
 }
}
