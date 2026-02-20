import 'package:flutter/material.dart';

/// The TikTok-style UI overlay for the video feed.
/// Extracts purely visual components to declutter the player widget.
class VideoOverlayUI extends StatelessWidget {
  final int index;
  final String title;

  const VideoOverlayUI({
    super.key,
    required this.index,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Bottom gradient overlay
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 200,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withAlpha(180),
                ],
              ),
            ),
          ),
        ),

        // Title + User Info + Description
        Positioned(
          left: 16,
          right: 80,
          bottom: 48,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '@user_$index',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.music_note, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    'Original Audio - @user_$index',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Right-side interactions
        Positioned(
          right: 12,
          bottom: 120,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProfileButton(),
              const SizedBox(height: 24),
              _buildIconButton(Icons.favorite, '1.2M'),
              const SizedBox(height: 20),
              _buildIconButton(Icons.comment, '4,231'),
              const SizedBox(height: 20),
              _buildIconButton(Icons.bookmark, '10.5K'),
              const SizedBox(height: 20),
              _buildIconButton(Icons.share, 'Share'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProfileButton() {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.grey[800],
            border: Border.all(color: Colors.white, width: 1.5),
            // Default placeholder if network image fails
            image: const DecorationImage(
              image: NetworkImage('https://picsum.photos/100/100'),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          bottom: -8,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Colors.pinkAccent,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add, color: Colors.white, size: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildIconButton(IconData icon, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          color: Colors.white,
          size: 34,
          shadows: const [Shadow(blurRadius: 10, color: Colors.black54)],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
          ),
        ),
      ],
    );
  }
}
