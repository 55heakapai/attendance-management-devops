package com.attendance.model;

public class StatusResponse {
    private String status;
    private String message;
    private String timestamp;
    private int totalRecords;

    public StatusResponse(String status, String message, String timestamp, int totalRecords) {
        this.status = status;
        this.message = message;
        this.timestamp = timestamp;
        this.totalRecords = totalRecords;
    }

    public String getStatus() { return status; }
    public String getMessage() { return message; }
    public String getTimestamp() { return timestamp; }
    public int getTotalRecords() { return totalRecords; }
}
