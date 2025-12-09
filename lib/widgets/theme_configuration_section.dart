import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'preset_card.dart';

class ThemeConfigurationSection extends StatelessWidget {
  const ThemeConfigurationSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1225),
        border: Border.all(color: const Color(0xFF1F2937)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [

          const Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme Configuration',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Upload your theme thumbnails and add URL details below.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFFCCCCCC),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Consumer<AppState>(
                  builder: (context, appState, child) {
                    return Checkbox(
                      value: appState.noEffectsEnabled,
                      onChanged: (value) => appState.toggleNoEffects(),
                      activeColor: const Color(0xFF7C3AED),
                      checkColor: Colors.white,
                    );
                  },
                ),
                const Text(
                  'No effects',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),

                Consumer<AppState>(
                  builder: (context, appState, child) {
                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2937),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildSwitchButton(
                            'Live',
                            appState.dataSource == 'live',
                            () => appState.setDataSource('live'),
                          ),
                          _buildSwitchButton(
                            'Post',
                            appState.dataSource == 'post',
                            () => appState.setDataSource('post'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          Expanded(
            child: Consumer<AppState>(
              builder: (context, appState, child) {
                if (appState.isLoading) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF7C3AED),
                    ),
                  );
                }
                
                if (appState.presets.isEmpty) {
                  return const Center(
                    child: Text(
                      'No presets found. Add your first theme below.',
                      style: TextStyle(
                        color: Color(0xFFCCCCCC),
                        fontSize: 14,
                      ),
                    ),
                  );
                }
                
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: appState.presets.length,
                  itemBuilder: (context, index) {
                    final preset = appState.presets[index];
                    return PresetCard(
                      preset: preset,
                      onEdit: () => _editPreset(context, preset),
                    );
                  },
                );
              },
            ),
          ),

        ],
      ),
    );
  }

  Widget _buildSwitchButton(String label, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF7C3AED) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFFCCCCCC),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }


  void _editPreset(BuildContext context, preset) {

    debugPrint('Edit preset: ${preset.title}');
  }

}


