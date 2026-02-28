# QNAP Dashboard - Enhanced Monitoring Guide

## Overview

This enhanced QNAP dashboard provides comprehensive monitoring for QNAP NAS systems using `qnapexporter` with Prometheus. The dashboard has been completely updated from the original SNMP-based version to work with modern Prometheus metrics.

## Dashboard Structure

### 1. System Overview Row
- **Uptime**: Shows system uptime in seconds
- **Total CPU Usage**: Current CPU utilization percentage
- **CPU Temperatures**: Real-time CPU temperature monitoring
- **System Load Average**: 1, 5, and 15-minute load averages with color-coded thresholds

### 2. System Performance Row
- **Memory Usage**: Current memory utilization with color-coded thresholds
- **Disk I/O Bandwidth**: Read and write bandwidth for all disk devices
- **Network Bandwidth**: Receive and transmit bandwidth for all network interfaces
- **Process Count**: Number of currently running processes

### 3. Cooling & Environment Row
- **Enclosure Temperature**: System enclosure temperature monitoring
- **S.M.A.R.T. (Disk Temperatures)**: Individual disk temperature monitoring
- **File Descriptors**: Allocated vs. maximum file descriptor usage
- **Volume Usage Percentage**: Percentage of volume space used with thresholds

### 4. Storage & Disks Row
- **Volume Usage**: Available vs. total volume space
- **Disk Temperatures (Timeseries)**: Historical disk temperature trends
- **IOPS**: Read and write operations per second for all disks
- **Latency**: Read and write latency for all disks
- **Swap Memory Usage**: Swap memory utilization over time

### 5. Network & Connectivity Row
- **Ethernet ports status**: Interface MTU, speed, and MAC address information
- **Network packets sent**: Transmit packet statistics
- **Network packets received**: Receive packet statistics
- **Error Packets**: Network error packet monitoring

### 6. Logs & Monitoring Row
- **Service status**: Service availability (Note: Not available with qnapexporter)
- **Logs**: Centralized log viewing with search capabilities

## New Features Added

### 1. System Load Average Panel
- **Purpose**: Monitor system load to identify performance bottlenecks
- **Thresholds**: 
  - Green: 0-1 (normal)
  - Yellow: 1-5 (warning)
  - Red: >5 (critical)
- **Metrics**: `node_load1`, `node_load5`, `node_load15`

### 2. Disk I/O Bandwidth Panel
- **Purpose**: Monitor disk performance and identify I/O bottlenecks
- **Metrics**: `rate(node_disk_read_bytes_total[5m])`, `rate(node_disk_write_bytes_total[5m])`
- **Units**: Bytes per second (Bps)
- **Grouping**: By device for per-disk monitoring

### 3. Network Bandwidth Panel
- **Purpose**: Monitor network performance and bandwidth utilization
- **Metrics**: `rate(node_network_receive_bytes_total[5m])`, `rate(node_network_transmit_bytes_total[5m])`
- **Units**: Bytes per second (Bps)
- **Grouping**: By device for per-interface monitoring

### 4. Process Count Panel
- **Purpose**: Monitor system process count for resource management
- **Metrics**: `node_procs_running`
- **Thresholds**:
  - Green: 0-100 (normal)
  - Yellow: 100-200 (warning)
  - Red: >200 (critical)

### 5. File Descriptors Panel
- **Purpose**: Monitor file descriptor usage to prevent "too many open files" errors
- **Metrics**: `node_filefd_allocated`, `node_filefd_maximum`
- **Units**: Count of file descriptors

### 6. Volume Usage Percentage Panel
- **Purpose**: Monitor volume space utilization with percentage-based thresholds
- **Metrics**: Calculated from `node_volume_avail_bytes` and `node_volume_size_bytes`
- **Thresholds**:
  - Green: 0-70% (normal)
  - Yellow: 70-90% (warning)
  - Red: >90% (critical)

### 7. Swap Memory Usage Panel
- **Purpose**: Monitor swap memory utilization for memory pressure detection
- **Metrics**: `node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes`
- **Units**: Bytes

## Enhanced Features

### 1. Improved Row Organization
- **System Overview**: Core system metrics at a glance
- **System Performance**: Performance and resource utilization
- **Cooling & Environment**: Temperature and environmental monitoring
- **Storage & Disks**: Storage performance and health
- **Network & Connectivity**: Network performance and status
- **Logs & Monitoring**: Logs and service monitoring

### 2. Better Time Range Options
- **Default**: Last 1 hour (changed from 3 hours)
- **Refresh Intervals**: 5s, 10s, 30s, 1m, 5m, 15m, 30m, 1h, 2h, 1d
- **Time Presets**: 5m, 15m, 1h, 6h, 12h, 24h, 2d, 7d, 30d

### 3. Enhanced Thresholds and Colors
- **Color Coding**: Green (normal), Yellow (warning), Red (critical)
- **Dynamic Thresholds**: Based on industry best practices
- **Visual Indicators**: Background colors and threshold lines

## Alerting Rules

The dashboard includes comprehensive alerting rules in `monitoring/prometheus/qnap-alerts.yml`:

### Memory Alerts
- **QNAPHighMemoryUsage**: Triggers when memory usage > 90%

### Storage Alerts
- **QNAPHighDiskUsage**: Triggers when volume usage > 90%

### Temperature Alerts
- **QNAPHighTemperature**: Triggers when temperatures exceed safe limits
  - Disk: > 50°C
  - CPU: > 80°C
  - System: > 60°C

### Performance Alerts
- **QNAPHighLoadAverage**: Triggers when system load is high
- **QNAPProcessCountHigh**: Triggers when process count > 200

### Network Alerts
- **QNAPHighNetworkErrors**: Triggers when network errors are detected

## Usage Tips

### 1. Monitoring Best Practices
- **Regular Checks**: Review dashboard at least daily
- **Threshold Monitoring**: Pay attention to yellow/red indicators
- **Trend Analysis**: Use time range presets to identify patterns
- **Alert Response**: Respond promptly to critical alerts

### 2. Performance Optimization
- **Load Average**: Keep below 1.0 for optimal performance
- **Memory Usage**: Keep below 80% to avoid swapping
- **Disk Usage**: Keep below 80% to maintain performance
- **Temperature**: Monitor for any unusual spikes

### 3. Troubleshooting
- **No Data**: Check if `qnapexporter` is running and accessible
- **High Values**: Use time range presets to identify when issues started
- **Network Issues**: Check both bandwidth and error panels
- **Storage Issues**: Monitor both usage and performance metrics

## Configuration

### 1. Prometheus Data Source
- **UID**: `dev7l1goqeozkc`
- **Type**: Prometheus
- **URL**: Your Prometheus instance URL

### 2. Loki Data Source (Logs)
- **UID**: `cev7l2ngxssg0a`
- **Type**: Loki
- **URL**: Your Loki instance URL

### 3. Template Variables
- **$node**: QNAP node name (auto-populated from `node_cpu_count`)
- **$sampling**: Sampling interval (default: 2m)
- **$search**: Log search term

## Maintenance

### 1. Regular Updates
- **Dashboard**: Update when new metrics become available
- **Alerts**: Review and adjust thresholds based on usage patterns
- **Documentation**: Keep this guide updated with changes

### 2. Performance Monitoring
- **Dashboard Load Time**: Should be under 5 seconds
- **Query Performance**: Monitor Prometheus query execution times
- **Storage**: Monitor Prometheus storage usage

### 3. Backup
- **Dashboard JSON**: Export and backup regularly
- **Alert Rules**: Backup alert configuration
- **Configuration**: Document any customizations

## Troubleshooting Common Issues

### 1. "No Data" Panels
- **Check qnapexporter**: Ensure it's running and accessible
- **Verify Metrics**: Check if metrics exist in Prometheus
- **Check Labels**: Ensure `$node` variable is set correctly

### 2. High Resource Usage
- **Load Average**: Check for runaway processes
- **Memory**: Look for memory leaks or high usage applications
- **Disk I/O**: Identify disk-intensive operations

### 3. Temperature Issues
- **Environmental**: Check room temperature and ventilation
- **Hardware**: Verify fan operation and dust buildup
- **Workload**: Monitor for sustained high CPU usage

## Future Enhancements

### 1. Additional Metrics
- **Power Consumption**: If available via qnapexporter
- **Fan Speeds**: Individual fan monitoring
- **RAID Status**: RAID health and performance metrics

### 2. Advanced Visualizations
- **Heat Maps**: For temperature and performance data
- **Gauge Panels**: For percentage-based metrics
- **Table Panels**: For detailed metric listings

### 3. Integration Features
- **Webhook Notifications**: For alert actions
- **External Monitoring**: Integration with other monitoring systems
- **Custom Dashboards**: User-specific dashboard views

## Support and Resources

### 1. Documentation
- **qnapexporter**: [GitHub Repository](https://github.com/qnap-dev/qnapexporter)
- **Prometheus**: [Official Documentation](https://prometheus.io/docs/)
- **Grafana**: [Official Documentation](https://grafana.com/docs/)

### 2. Community
- **QNAP Forums**: Community support and discussions
- **GitHub Issues**: Report bugs and request features
- **Discord/Slack**: Real-time community support

### 3. Professional Support
- **QNAP Support**: Official QNAP technical support
- **Monitoring Consultants**: Professional monitoring setup and optimization
- **System Administrators**: Local IT support teams

---

*This dashboard is designed to provide comprehensive monitoring for QNAP NAS systems. Regular maintenance and updates ensure optimal performance and early detection of potential issues.*
