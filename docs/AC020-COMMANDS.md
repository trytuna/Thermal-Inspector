# Camera command table (InfiRay "AC020" command set)

The P3 is built around an InfiRay thermal module. The official Android app
("Thermal Master" 2.3.11) talks to it through InfiRay's command library
`libircmd020.so`. Its exported functions build the same 16-byte commands that we
recorded between the iPhone app and the camera, so their names tell what each
command does.

How this table was made: the library was disassembled and, for every function, the
value stored as command type (bytes 0–1) and as sub-command (byte 2) right before
the call to `standard_cmd_write` / `standard_cmd_read` was extracted automatically.
Where two functions share a code, the extraction may have picked up a value of a
neighbouring code path – treat those rows as unverified.

## Command layout

    byte 0–1   command type (little-endian), e.g. 10 04 = image settings
    byte 2     sub-command: 0x4x = set ("write"), 0x8x = get ("read"), 0xCx = write data
    byte 3     0
    byte 4–5   value / register (little-endian)
    byte 6–11  further parameters / 0
    byte 12–15 length of the answer for "get" commands (little-endian)
    + CRC-16/XMODEM (2 bytes, little-endian); over the iPhone connection also the
      4-byte header (see HARDWARE-NOTES.md)

## Verified with the P3

| Command | Function | Seen / tested |
|---|---|---|
| `10 02 41 00 <0/1>` | `basic_auto_ffc_status_set` | automatic shutter off/on – verified by ear |
| `10 02 43` | `basic_ffc_update` | shutter now (iPhone app) – verified |
| `01 36 43` | `adv_manual_ffc_update` | shutter now (USB, Mac) – verified |
| `01 2f 41 00 <0/1>` | `basic_gain_set` | gain low/high – verified |
| `10 04 47 00 <0…100>` | `basic_image_brightness_level_set` | official app sends 48–50 on connect; on the Mac 0 makes the camera's gray image black, 100 white |
| `10 04 4a 00 <0…100>` | `basic_global_contrast_level_set` | official app sends 50 on connect ("view contrast") |
| `10 04 44 00 <0…100>` | `basic_image_noise_reduction_level_set` | not used by the official app for the P3; 100 makes the gray image visibly smoother than 0 |
| `10 04 45 00 <0…100>` | `basic_image_detail_enhance_level_set` | not used by the official app for the P3; no visible difference on a flat scene – not verified |
| `10 03 4b 00 <0/1>` | `basic_sun_detect_switch_set` | official app sends 1 on connect ("anti-burn protection", default on); accepted (status 3), effect not tested |
| `01 01 81` | `basic_device_info_get` | read name, version, serial … |
| `10 21 81` | `eeprom_system_data_update_flag_read` | official app reads it when opening its settings |

The image settings only change the camera's 8-bit gray image, never the
temperature data. All values above 100 are rejected by the library.

## Reading values does not work yet

"Get" commands (sub-command `0x8x`, e.g. `10 10 91` device temperature,
`10 04 87` brightness) are accepted over USB, but the vendor "read response"
request (0xC1/0x21) only returns stale bytes – the buffer is never cleared. The
library sends such commands over the bulk OUT endpoint and reads the answer from
bulk IN 0x81, i.e. mixed into the image stream. Supporting that would mean
separating answers from image data. The device temperature (`basic_device_temp_get`:
2 bytes, value / 100 = °C) is therefore not shown yet.

## Do NOT send

These change or erase the camera's calibration or firmware state and may break
the camera: everything with `reset_to_rom`, `reset_to_bootloader`,
`file_update_mode`, `reboot`, `device_info_set`, `cfg_file_*`, `*_save`, `*_clear`,
`*_restore`, `k_value_*`, `dpc_*`, `rmcover_*`, `recal_tpd_*`, `tpd_parameters_set*`,
`ooc_data_save_to_flash`, `algorithm_parameters_write`, `eeprom_*_write`.

## All extracted commands

| Command | R/W | Function |
|---|---|---|
| `01 01 41` | W | `adv_basic_reset_to_normal` |
| `01 01 41` | W | `adv_enter_reboot_mode2` |
| `01 01 42` | W | `basic_reset_to_rom` |
| `01 01 47` | W | `basic_reset_to_bootloader` |
| `01 01 48` | W | `adv_enter_file_update_mode` |
| `01 01 49` | W | `adv_leave_file_update_mode` |
| `01 01 4a` | W | `adv_enter_reboot_mode` |
| `01 01 81` | R | `basic_device_info_get` |
| `01 01 82` | R | `basic_device_current_status_get` |
| `01 01 83` | R | `basic_long_time_vdcmd_state_get` |
| `01 01 cb` | W | `adv_device_info_set` |
| `01 02 48` | W | `adv_delay_chain_save` |
| `01 02 48` | W | `adv_save_default_param` |
| `01 0e 81` | R | `adv_ddr_data_get` |
| `01 0f 45` | W | `adv_shutter_tab_close` |
| `01 0f 45` | W | `adv_shutter_tab_open` |
| `01 0f 49` | W | `adv_ooc_data_save_to_flash` |
| `01 0f 86` | R | `adv_device_realtime_status_get` |
| `01 10 52` | W | `adv_ffc_without_shutter` |
| `01 26 41` | W | `adv_tpd_parameters_set_ddr` |
| `01 26 48` | W | `adv_bypass_nuct_set` |
| `01 26 48` | W | `adv_nuc_t_bypass_set` |
| `01 26 49` | W | `adv_tpd_parameters_set` |
| `01 26 81` | R | `adv_tpd_k_b_addr_ca_get_new` |
| `01 26 88` | R | `adv_bypass_nuct_get` |
| `01 26 89` | R | `adv_image_center_avg_array_get` |
| `01 26 89` | R | `adv_tpd_area_array_get` |
| `01 2c 49` | W | `mirror_status_set` |
| `01 2c 83` | R | `mirror_status_get` |
| `01 2f 41` | W | `basic_gain_set` |
| `01 2f 81` | R | `basic_gain_get` |
| `01 30 c2` | W | `basic_preview_stop` |
| `01 31 42` | W | `basic_center_zoom_set` |
| `01 31 51` | W | `adv_coordinate_zoom_set` |
| `01 31 52` | W | `adv_equal_proportion_zoom_set` |
| `01 31 53` | W | `adv_device_pip_status_set` |
| `01 31 82` | R | `basic_center_zoom_get` |
| `01 31 93` | R | `adv_device_pip_status_get` |
| `01 32 83` | R | `basic_palette_num_get` |
| `01 35 41` | W | `flip_status_set` |
| `01 35 42` | W | `adv_palette_switch_set` |
| `01 35 81` | R | `flip_status_get` |
| `01 36 43` | W | `adv_manual_ffc_update` |
| `01 37 82` | R | `basic_firmware_log_data_get` |
| `01 42 83` | R | `adv_device_preview_info_get` |
| `01 44 41` | W | `adv_baudrate_set` |
| `03 02 42` | W | `adv_tpd_point_coord_set` |
| `03 02 43` | W | `adv_tpd_line_coord_set` |
| `03 02 44` | W | `adv_tpd_rect_coord_set` |
| `03 02 51` | W | `adv_show_frame_temp` |
| `03 02 52` | W | `adv_show_point_temp` |
| `03 02 81` | R | `basic_frame_temp_info_get` |
| `10 01 46` | W | `adv_cache_clear` |
| `10 02 41` | W | `basic_auto_ffc_status_set` |
| `10 02 42` | W | `basic_auto_ffc_current_params_set` |
| `10 02 43` | W | `basic_ffc_update` |
| `10 02 44` | W | `adv_manual_ffc_switch_set` |
| `10 02 44` | W | `adv_shutter_status_set` |
| `10 02 81` | R | `basic_auto_ffc_status_get` |
| `10 02 82` | R | `basic_auto_ffc_current_params_get` |
| `10 02 83` | R | `adv_manual_ffc_switch_get` |
| `10 02 83` | R | `adv_shutter_status_get` |
| `10 03 45` | W | `basic_palette_idx_set` |
| `10 03 46` | W | `adv_isothermal_mode_set` |
| `10 03 48` | W | `adv_isothermal_switch_set` |
| `10 03 49` | W | `basic_sun_detect_pixel_ratio_set` |
| `10 03 4a` | W | `basic_sun_detect_roundness_level_set` |
| `10 03 4b` | W | `basic_sun_detect_switch_set` |
| `10 03 4c` | W | `basic_all_ffc_function_status_set` |
| `10 03 4c` | W | `basic_overexposure_protect_switch_set` |
| `10 03 4d` | W | `adv_yuv_format_set` |
| `10 03 81` | R | `adv_device_preview_info_get` |
| `10 03 82` | R | `adv_info_line_get` |
| `10 03 85` | R | `basic_palette_idx_get` |
| `10 03 86` | R | `adv_isothermal_mode_get` |
| `10 03 88` | R | `adv_isothermal_switch_get` |
| `10 03 89` | R | `basic_sun_detect_pixel_ratio_get` |
| `10 03 8a` | R | `basic_sun_detect_roundness_level_get` |
| `10 03 8b` | R | `basic_sun_detect_switch_get` |
| `10 03 8c` | R | `adv_yuv_format_get` |
| `10 03 8d` | R | `basic_all_ffc_function_status_get` |
| `10 03 8d` | R | `basic_overexposure_protect_switch_get` |
| `10 03 8e` | R | `basic_sun_detect_status_get` |
| `10 04 42` | W | `basic_image_scene_mode_set` |
| `10 04 42` | W | `basic_scene_mode_set` |
| `10 04 44` | W | `basic_image_noise_reduction_level_set` |
| `10 04 45` | W | `basic_image_detail_enhance_level_set` |
| `10 04 46` | W | `basic_image_roi_level_set` |
| `10 04 47` | W | `basic_image_brightness_level_set` |
| `10 04 48` | W | `basic_image_contrast_level_set` |
| `10 04 4a` | W | `basic_global_contrast_level_set` |
| `10 04 4b` | W | `basic_algorithm_parameters_save` |
| `10 04 4b` | W | `basic_space_noise_reduce_level_set` |
| `10 04 4c` | W | `basic_time_noise_reduce_level_set` |
| `10 04 4d` | W | `basic_algorithm_parameters_restore` |
| `10 04 4d` | W | `basic_gamma_rate_set` |
| `10 04 4d` | W | `basic_restore_default_data` |
| `10 04 4e` | W | `adv_cel_level_set` |
| `10 04 4e` | W | `adv_edge_enhance_set` |
| `10 04 4f` | W | `adv_cel_level_restore` |
| `10 04 50` | W | `adv_homogeneity_algorithm_set` |
| `10 04 50` | W | `adv_profession_mode_set` |
| `10 04 51` | W | `adv_profession_scene_level_save` |
| `10 04 51` | W | `adv_shutter_abnormal_detect_algorithm_set` |
| `10 04 52` | W | `adv_homogeneity_agc_dde_algorithm_set` |
| `10 04 52` | W | `adv_profession_scene_level_restore` |
| `10 04 52` | W | `basic_restore_default_data` |
| `10 04 84` | R | `basic_current_image_noise_reduction_level_get` |
| `10 04 85` | R | `basic_current_detail_enhance_level_get` |
| `10 04 86` | R | `basic_current_image_roi_level_get` |
| `10 04 87` | R | `basic_current_brightness_level_get` |
| `10 04 88` | R | `basic_current_contrast_level_get` |
| `10 04 89` | R | `basic_current_image_scene_mode_get` |
| `10 04 89` | R | `basic_scene_mode_get` |
| `10 04 8a` | R | `basic_global_contrast_level_get` |
| `10 04 8b` | R | `basic_space_noise_reduce_level_get` |
| `10 04 8c` | R | `basic_time_noise_reduce_level_get` |
| `10 04 8d` | R | `basic_current_gamma_level_get` |
| `10 04 8e` | R | `adv_edge_enhance_get` |
| `10 04 8e` | R | `adv_profession_mode_get` |
| `10 04 8f` | R | `adv_cel_level_get` |
| `10 04 90` | R | `adv_homogeneity_algorithm_get` |
| `10 04 91` | R | `adv_shutter_abnormal_detect_algorithm_get` |
| `10 04 92` | R | `adv_homogeneity_agc_dde_algorithm_get` |
| `10 05 41` | W | `basic_video_stream_continue` |
| `10 05 41` | W | `basic_video_stream_pause` |
| `10 05 42` | W | `adv_mipi_channel_type_set` |
| `10 05 44` | W | `adv_stream_source_mode_reset` |
| `10 05 45` | W | `adv_tir_stream_source_set` |
| `10 05 81` | R | `adv_video_driver_status_get` |
| `10 06 41` | W | `adv_recal_tpd_by_1point` |
| `10 06 42` | W | `adv_second_cali_flag_reset` |
| `10 06 42` | W | `basic_all_recal_data_restore` |
| `10 06 42` | W | `basic_restore_default_data` |
| `10 06 47` | W | `adv_multi_rmcover_calib` |
| `10 06 48` | R | `adv_multirmcover_param_set` |
| `10 06 81` | R | `adv_second_cali_flag_get` |
| `10 07 41` | W | `adv_external_trigger_shutterless` |
| `10 07 42` | W | `adv_env_correct_tu_set` |
| `10 07 42` | W | `snr_homogeneity_set` |
| `10 07 43` | W | `adv_env_correct_ta_set` |
| `10 07 44` | W | `adv_env_correct_ems_set` |
| `10 07 45` | W | `adv_env_correct_tau_set` |
| `10 07 46` | W | `adv_env_correct_switch_set` |
| `10 07 82` | R | `snr_homogeneity_get` |
| `10 07 86` | R | `adv_env_correct_switch_get` |
| `10 08 46` | W | `adv_cfg_file_close` |
| `10 08 48` | W | `adv_cfg_file_close_all` |
| `10 08 48` | W | `adv_cfg_file_modify_crc` |
| `10 08 86` | R | `adv_cfg_file_read` |
| `10 08 88` | R | `adv_cfg_read_second_cali_oem` |
| `10 08 89` | R | `adv_firmware_type_get` |
| `10 08 c1` | W | `adv_cfg_file_write` |
| `10 08 c1` | W | `adv_cfg_file_write_multipart` |
| `10 08 c6` | W | `adv_cfg_read_second_cali_oem` |
| `10 08 c6` | W | `adv_cfg_set_path` |
| `10 08 c6` | W | `adv_cfg_write_second_cali_oem` |
| `10 08 c7` | W | `adv_cfg_file_open` |
| `10 08 c7` | W | `test_flash_read_file_open` |
| `10 08 ca` | W | `adv_cfg_write_second_cali_oem` |
| `10 10 41` | W | `adv_boot_logo_status_set` |
| `10 10 42` | W | `adv_picture_freeze_status_set` |
| `10 10 43` | W | `basic_mirror_and_flip_status_set` |
| `10 10 44` | W | `adv_output_frame_rate_set` |
| `10 10 45` | W | `adv_stream_mid_mode_set` |
| `10 10 46` | W | `adv_digital_video_output_set` |
| `10 10 47` | W | `adv_voltage_change_set` |
| `10 10 48` | W | `adv_device_sleep_set` |
| `10 10 4a` | W | `adv_analog_video_output_set` |
| `10 10 4b` | W | `adv_external_synchronization_set` |
| `10 10 4c` | W | `adv_7393_analog_set` |
| `10 10 4d` | W | `adv_palette_analog_set` |
| `10 10 4d` | W | `thermometry_preview_start` |
| `10 10 51` | W | `basic_system_parameter_save` |
| `10 10 52` | W | `basic_restore_default_data` |
| `10 10 52` | W | `basic_system_parameter_restore` |
| `10 10 53` | W | `adv_stream_mid_permission_set` |
| `10 10 53` | W | `heart_packet_start` |
| `10 10 54` | W | `heart_packet_send` |
| `10 10 5c` | W | `adv_vl_parameters_write` |
| `10 10 66` | W | `adv_crg_value_set` |
| `10 10 68` | W | `adv_crg_value_save` |
| `10 10 81` | R | `adv_boot_logo_status_get` |
| `10 10 82` | R | `adv_picture_freeze_status_get` |
| `10 10 85` | R | `adv_stream_mid_mode_get` |
| `10 10 86` | R | `adv_digital_video_output_get` |
| `10 10 87` | R | `adv_voltage_change_get` |
| `10 10 88` | R | `adv_device_sleep_get` |
| `10 10 8b` | R | `adv_external_synchronization_get` |
| `10 10 8d` | R | `basic_preview_info_get` |
| `10 10 91` | R | `basic_device_temp_get` |
| `10 10 92` | R | `adv_temp_coordinate_of_interest_get` |
| `10 10 93` | R | `adv_powered_time_get` |
| `10 10 94` | R | `adv_vtemp_k_n_get` |
| `10 10 9c` | R | `adv_vl_parameters_read` |
| `10 10 9f` | R | `adv_ir_test_value_get` |
| `10 10 a6` | R | `adv_crg_value_get` |
| `10 11 41` | W | `adv_k_value_calibration` |
| `10 11 42` | W | `adv_k_value_calibration_cancel` |
| `10 11 43` | W | `adv_k_value_save` |
| `10 11 44` | W | `adv_k_value_clear` |
| `10 11 45` | W | `adv_k_value_restore` |
| `10 11 45` | W | `basic_restore_default_data` |
| `10 11 53` | W | `adv_dpc_calib_data_cancel` |
| `10 11 54` | W | `adv_dpc_calib_data_save` |
| `10 11 55` | W | `adv_dpc_calib_data_clear` |
| `10 11 56` | W | `adv_dpc_calib_data_restore` |
| `10 11 56` | W | `basic_restore_default_data` |
| `10 11 57` | W | `adv_cursor_switch_status_set` |
| `10 11 58` | W | `adv_cursor_position_set` |
| `10 11 62` | W | `adv_rmcover_calib_cancel` |
| `10 11 63` | W | `adv_rmcover_calib_save` |
| `10 11 64` | W | `adv_rmcover_calib_clear` |
| `10 11 65` | W | `adv_rmcover_calib_restore` |
| `10 11 65` | W | `basic_restore_default_data` |
| `10 11 72` | W | `adv_recal_tpd_by_1point_cancel` |
| `10 11 73` | W | `adv_recal_tpd_by_1point_save` |
| `10 11 74` | W | `adv_recal_tpd_by_1point_clear` |
| `10 11 75` | W | `basic_restore_default_data` |
| `10 11 75` | W | `basic_tpd_data_restore` |
| `10 11 77` | W | `adv_recal_tpd_by_2point_cancel` |
| `10 11 78` | W | `adv_recal_tpd_by_2point_save` |
| `10 11 79` | W | `adv_recal_tpd_by_2point_clear` |
| `10 11 7a` | W | `basic_restore_default_data` |
| `10 11 7a` | W | `basic_tpd_data_2point_restore` |
| `10 11 81` | R | `adv_cursor_switch_status_get` |
| `10 11 82` | R | `adv_cursor_position_get` |
| `10 20 81` | R | `adv_algorithm_parameters_read` |
| `10 20 81` | R | `adv_fpga_version_get` |
| `10 20 c1` | W | `adv_algorithm_parameters_write` |
| `10 21 81` | R | `eeprom_system_data_update_flag_read` |
| `10 21 c1` | W | `eeprom_system_data_update_flag_write` |
