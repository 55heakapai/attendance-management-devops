package com.attendance.model;

public class AttendanceRecord {
    private String id;
    private String userId;
    private String userName;
    private String checkInTime;
    private String status;
    private String location;

    public AttendanceRecord(String id, String userId, String userName,
                            String checkInTime, String status, String location) {
        this.id = id;
        this.userId = userId;
        this.userName = userName;
        this.checkInTime = checkInTime;
        this.status = status;
        this.location = location;
    }

    public String getId() { return id; }
    public String getUserId() { return userId; }
    public String getUserName() { return userName; }
    public String getCheckInTime() { return checkInTime; }
    public String getStatus() { return status; }
    public String getLocation() { return location; }
}
