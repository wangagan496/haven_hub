import 'package:flutter/material.dart';
import 'cached_image.dart';
import 'image_preview.dart';

class RepairPhotos extends StatelessWidget {
  const RepairPhotos(
      {required this.urls,
      this.onRemove,
      this.onAdd,
      this.editable = false,
      this.uploading = false,
      this.selectedCount,
      super.key});
  final List<String> urls;
  final ValueChanged<int>? onRemove;
  final VoidCallback? onAdd;
  final bool editable;
  final bool uploading;
  final int? selectedCount;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(
            editable
                ? '现场照片（${selectedCount ?? urls.length}/8）'
                : '现场照片（${urls.length}张）',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, constraints) {
          final int columns =
              ((constraints.maxWidth + 12) / 108).floor().clamp(1, 4);
          final double size =
              ((constraints.maxWidth - (columns - 1) * 12) / columns)
                  .clamp(0, 160)
                  .toDouble();
          return SizedBox(
              width: columns * size + (columns - 1) * 12,
              child: Wrap(spacing: 12, runSpacing: 12, children: <Widget>[
                for (int i = 0; i < urls.length; i++)
                  SizedBox(
                      width: size,
                      child: Column(children: <Widget>[
                        Semantics(
                            label: '查看第${i + 1}张现场照片',
                            button: true,
                            child: InkWell(
                                onTap: () => showDialog<void>(
                                    context: context,
                                    builder: (_) => ImagePreview(
                                        child: CachedImage(
                                            imageUrl: urls[i],
                                            fit: BoxFit.contain))),
                                child: SizedBox.square(
                                    key: ValueKey('repair-photo-$i'),
                                    dimension: size,
                                    child: DecoratedBox(
                                      position: DecorationPosition.foreground,
                                      decoration: BoxDecoration(
                                        border:
                                            Border.all(color: Colors.black12),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: ColoredBox(
                                          color: Colors.white,
                                          child: CachedImage(
                                            imageUrl: urls[i],
                                            errorWidget: const Center(
                                                child: Icon(Icons
                                                    .broken_image_outlined)),
                                          ),
                                        ),
                                      ),
                                    )))),
                        if (editable)
                          IconButton(
                              tooltip: '删除第${i + 1}张照片',
                              onPressed:
                                  uploading ? null : () => onRemove?.call(i),
                              icon: const Icon(Icons.close)),
                      ])),
                if (editable)
                  SizedBox(
                      width: size,
                      height: size,
                      child: OutlinedButton(
                        key: const ValueKey('add-repair-photo'),
                        onPressed:
                            (selectedCount ?? urls.length) >= 8 || uploading
                                ? null
                                : onAdd,
                        child: uploading
                            ? const SizedBox.square(
                                dimension: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                    Icon(Icons.add_photo_alternate_outlined),
                                    Text('添加照片')
                                  ]),
                      )),
              ]));
        }),
        if (!editable && urls.isNotEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('点击照片查看大图',
                  style: TextStyle(fontSize: 12, color: Colors.grey))),
        if (uploading)
          const Padding(
              padding: EdgeInsets.only(top: 8), child: Text('正在上传，请稍候…')),
      ]);
}
