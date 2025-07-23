#!/usr/bin/env python3
"""
NAS Backup Status API Server

Provides HTTP endpoints to retrieve the last backup run status in JSON or XML format.
Hides last job information when a backup is currently running.
"""

import os
import json
import time
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import xml.etree.ElementTree as ET
import xml.dom.minidom

# Configuration
JOB_STATUS_FILE = "/Users/ryanhoulihan/Library/Logs/nasbackup_job_status.log"
LOCKFILE = "/tmp/nasbackup.lock"
PORT = 8080

class StatusAPIHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/api/status/last-run':
            self.handle_last_run_status(parsed_path)
        elif parsed_path.path == '/health':
            self.handle_health_check()
        else:
            self.send_error(404, "Endpoint not found")
    
    def handle_health_check(self):
        """Simple health check endpoint"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = {"status": "healthy", "timestamp": datetime.now().isoformat()}
        self.wfile.write(json.dumps(response).encode())
    
    def handle_last_run_status(self, parsed_path):
        """Handle the last run status endpoint"""
        try:
            # Parse query parameters
            query_params = parse_qs(parsed_path.query)
            output_format = query_params.get('format', ['json'])[0].lower()
            
            # Get status data
            status_data = self.get_last_run_status()
            
            # Send response based on format
            if output_format == 'xml':
                self.send_xml_response(status_data)
            else:
                self.send_json_response(status_data)
                
        except Exception as e:
            self.send_error(500, f"Internal server error: {str(e)}")
    
    def get_last_run_status(self):
        """Extract last run status from job status file"""
        is_running = self.is_backup_running()
        
        status_data = {
            "timestamp": datetime.now().isoformat(),
            "is_job_running": is_running,
        }
        
        # Only include last job info if no job is currently running
        if not is_running:
            status_data["last_job_id"] = None
            status_data["last_job_timestamp"] = None
            status_data["last_job_status"] = None
        
        # Read the job status file to get the last completed job
        if os.path.exists(JOB_STATUS_FILE) and not is_running:
            try:
                with open(JOB_STATUS_FILE, 'r') as f:
                    lines = f.readlines()
                
                # Find the last JOB_END entry
                last_job_end = None
                for line in reversed(lines):
                    if line.startswith('JOB_END|'):
                        last_job_end = line.strip()
                        break
                
                if last_job_end:
                    # Parse: JOB_END|job_id|timestamp|status|unsynced_files
                    parts = last_job_end.split('|')
                    if len(parts) >= 4:
                        status_data["last_job_id"] = parts[1]
                        status_data["last_job_timestamp"] = parts[2]
                        status_data["last_job_status"] = parts[3]
                            
            except Exception as e:
                # If we can't read the file, log the error but continue
                status_data["error"] = f"Could not read job status file: {str(e)}"
        
        return status_data
    
    def is_backup_running(self):
        """Check if a backup job is currently running"""
        if not os.path.exists(LOCKFILE):
            return False
        
        try:
            with open(LOCKFILE, 'r') as f:
                pid = int(f.read().strip())
            
            # Check if the process is still running
            try:
                os.kill(pid, 0)  # Signal 0 just checks if process exists
                return True
            except OSError:
                # Process doesn't exist
                return False
                
        except (ValueError, FileNotFoundError):
            return False
    
    def send_json_response(self, data):
        """Send JSON response"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        json_response = json.dumps(data, indent=2)
        self.wfile.write(json_response.encode())
    
    def send_xml_response(self, data):
        """Send XML response"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/xml')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        # Create XML structure
        root = ET.Element('backup_status')
        
        for key, value in data.items():
            elem = ET.SubElement(root, key)
            if value is not None:
                elem.text = str(value)
        
        # Pretty print XML
        rough_string = ET.tostring(root, 'unicode')
        reparsed = xml.dom.minidom.parseString(rough_string)
        pretty_xml = reparsed.toprettyxml(indent="  ")
        
        # Remove the first line (XML declaration) and empty lines
        lines = [line for line in pretty_xml.split('\n') if line.strip()]
        pretty_xml = '\n'.join(lines[1:])  # Skip XML declaration
        
        self.wfile.write(pretty_xml.encode())

def main():
    """Start the HTTP server"""
    server_address = ('', PORT)
    httpd = HTTPServer(server_address, StatusAPIHandler)
    
    print(f"NAS Backup Status API Server starting on port {PORT}")
    print(f"Endpoints:")
    print(f"  GET /api/status/last-run         - Get last run status (JSON)")
    print(f"  GET /api/status/last-run?format=xml - Get last run status (XML)")
    print(f"  GET /health                      - Health check")
    print(f"")
    print(f"Job Status File: {JOB_STATUS_FILE}")
    print(f"Lock File: {LOCKFILE}")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()

if __name__ == '__main__':
    main()
