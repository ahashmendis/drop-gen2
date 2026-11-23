package edu.practice.scheduler.error;
import edu.practice.scheduler.dto.ApiError;import org.springframework.http.*;import org.springframework.web.bind.annotation.*;
@RestControllerAdvice public class ApiExceptionHandler {
 @ExceptionHandler(IllegalArgumentException.class)
 public ResponseEntity<ApiError> badRequest(IllegalArgumentException e){return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(new ApiError("BAD_REQUEST",e.getMessage()));}
 @ExceptionHandler(WorkloadNotFoundException.class)
 public ResponseEntity<ApiError> notFound(WorkloadNotFoundException e){return ResponseEntity.status(HttpStatus.NOT_FOUND).body(new ApiError("NOT_FOUND",e.getMessage()));}
 @ExceptionHandler(CommitConflictException.class)
 public ResponseEntity<ApiError> conflict(CommitConflictException e){return ResponseEntity.status(HttpStatus.CONFLICT).body(new ApiError("CONFLICT",e.getMessage()));}
}
