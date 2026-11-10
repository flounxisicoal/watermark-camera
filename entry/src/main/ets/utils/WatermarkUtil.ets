import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 水印样式
 */
export enum WatermarkStyle {
  /** 经典：半透明底衬 + 文字 */
  CLASSIC = 0,
  /** 简约：无底衬，文字带阴影 */
  MINIMAL = 1,
  /** 描边：文字 + 对比色描边 */
  OUTLINE = 2,
  /** 强调：彩色底衬 + 对比色粗体文字 */
  ACCENT = 3
}

/**
 * 水印选项
 */
export interface WatermarkOptions {
  /** 自定义文字（可为空） */
  text: string;
  /** 是否显示时间戳 */
  showTimestamp: boolean;
  /** 时间戳字符串 */
  timestamp: string;
  /** 样式 */
  style: WatermarkStyle;
  /** 位置：0~8，按行优先（0 左上、4 居中、8 右下） */
  position: number;
  /** 字号缩放：0.8 / 1.0 / 1.3 */
  fontScale: number;
  /** 透明度：0.2 ~ 1.0 */
  opacity: number;
  /** 颜色（#RRGGBB）：经典/简约/描边为文字色，强调为底色 */
  color: string;
  /** 是否使用自由拖动位置 */
  useCustomPosition: boolean;
  /** 自由位置 X：0~1（相对预览宽度） */
  x: number;
  /** 自由位置 Y：0~1（相对预览高度） */
  y: number;
}

/**
 * 水印工具类
 *
 * 核心能力：
 *  1. 按用户选择绘制水印（文字、时间戳、样式、位置、字号、颜色、透明度），
 *     直接写进照片像素，生成不可去除的水印照片。
 *  2. 将 PixelMap 编码为 JPEG 字节流（ImagePacker）。
 *  3. 把字节流写入应用沙箱文件（@kit.CoreFileKit）。
 *
 * 注意：原片不做任何绘制，单独保存，从而满足“保留一张没有水印的照片”。
 */
export class WatermarkUtil {

  /**
   * 为 PixelMap 添加水印，返回新的 PixelMap。
   * 注意：OffscreenCanvas 的坐标系是 vp，而图片尺寸是 px，
   * 需要先换算成 vp，否则输出会被按屏幕密度放大。
   */
  static addTimestampWatermark(pixelMap: image.PixelMap, options: WatermarkOptions): image.PixelMap {
    const info: image.ImageInfo = pixelMap.getImageInfoSync();
    const widthPx: number = info.size.width;
    const heightPx: number = info.size.height;

    // px -> vp，保证画布尺寸与图片像素一一对应
    const widthVp: number = px2vp(widthPx);
    const heightVp: number = px2vp(heightPx);

    const offscreen: OffscreenCanvas = new OffscreenCanvas(widthVp, heightVp);
    const ctx: OffscreenCanvasRenderingContext2D =
      offscreen.getContext('2d') as OffscreenCanvasRenderingContext2D;

    // 1. 先绘制原图
    ctx.drawImage(pixelMap, 0, 0, widthVp, heightVp);

    // 2. 组合水印文字
    const content: string = WatermarkUtil.buildText(options);
    if (content === '') {
      // 既没有自定义文字也不显示时间戳：只导出原图
      return ctx.getPixelMap(0, 0, widthVp, heightVp);
    }

    // 3. 计算排版
    const margin: number = Math.round(widthVp * 0.03);
    const fontSize: number = Math.max(12, Math.round(widthVp * 0.035 * options.fontScale));
    let col: number = options.position % 3;
    let row: number = Math.floor(options.position / 3);
    let x: number = 0;
    let y: number = 0;
    if (options.useCustomPosition) {
      // 自由拖动：以文字中心为锚点
      x = Math.min(0.97, Math.max(0.03, options.x)) * widthVp;
      y = Math.min(0.97, Math.max(0.03, options.y)) * heightVp;
      col = 1;
      row = 1;
    } else {
      x = col === 0 ? margin : (col === 1 ? widthVp / 2 : widthVp - margin);
      y = row === 0 ? margin : (row === 1 ? heightVp / 2 : heightVp - margin);
    }
    const align: string = col === 0 ? 'left' : (col === 1 ? 'center' : 'right');
    const baseline: string = row === 0 ? 'top' : (row === 1 ? 'middle' : 'bottom');
    if (align === 'left') {
      ctx.textAlign = 'left';
    } else if (align === 'center') {
      ctx.textAlign = 'center';
    } else {
      ctx.textAlign = 'right';
    }
    if (baseline === 'top') {
      ctx.textBaseline = 'top';
    } else if (baseline === 'middle') {
      ctx.textBaseline = 'middle';
    } else {
      ctx.textBaseline = 'bottom';
    }

    const textColor: string = options.color;
    const bold: string = options.style === WatermarkStyle.ACCENT ? 'bold ' : '';
    ctx.font = `${bold}${fontSize}vp sans-serif`;
    const textWidth: number = ctx.measureText(content).width;
    const padding: number = Math.round(fontSize * 0.45);
    const alpha: number = Math.min(1, Math.max(0.2, options.opacity));
    ctx.globalAlpha = alpha;

    // 4. 底衬（经典 / 强调）
    if (options.style === WatermarkStyle.CLASSIC || options.style === WatermarkStyle.ACCENT) {
      const barWidth: number = textWidth + padding * 2;
      const barHeight: number = fontSize + padding * 2;
      let barX: number = x - padding;
      if (col === 1) {
        barX = x - barWidth / 2;
      } else if (col === 2) {
        barX = x - textWidth - padding;
      }
      let barY: number = y - padding;
      if (row === 1) {
        barY = y - barHeight / 2;
      } else if (row === 2) {
        barY = y - fontSize - padding;
      }
      if (options.style === WatermarkStyle.ACCENT) {
        ctx.fillStyle = textColor;
      } else {
        ctx.fillStyle = WatermarkUtil.isDarkColor(textColor)
          ? 'rgba(255, 255, 255, 0.75)'
          : 'rgba(0, 0, 0, 0.45)';
      }
      ctx.fillRect(barX, barY, barWidth, barHeight);
    }

    // 5. 绘制文字
    if (options.style === WatermarkStyle.ACCENT) {
      // 强调：底色为用户所选颜色，文字自动取对比色
      ctx.fillStyle = WatermarkUtil.isDarkColor(textColor) ? '#FFFFFF' : '#000000';
      ctx.fillText(content, x, y);
    } else if (options.style === WatermarkStyle.MINIMAL) {
      // 简约：文字 + 对比色投影
      ctx.shadowColor = WatermarkUtil.isDarkColor(textColor)
        ? 'rgba(255, 255, 255, 0.75)'
        : 'rgba(0, 0, 0, 0.75)';
      ctx.shadowBlur = Math.round(fontSize * 0.6);
      ctx.fillStyle = textColor;
      ctx.fillText(content, x, y);
      ctx.shadowBlur = 0;
    } else if (options.style === WatermarkStyle.OUTLINE) {
      // 描边：所选颜色填充 + 对比色描边
      ctx.lineWidth = Math.max(2, Math.round(fontSize * 0.14));
      ctx.strokeStyle = WatermarkUtil.isDarkColor(textColor) ? '#FFFFFF' : '#000000';
      ctx.strokeText(content, x, y);
      ctx.fillStyle = textColor;
      ctx.fillText(content, x, y);
    } else {
      // 经典
      ctx.fillStyle = textColor;
      ctx.fillText(content, x, y);
    }

    ctx.globalAlpha = 1;
    return ctx.getPixelMap(0, 0, widthVp, heightVp);
  }

  private static buildText(options: WatermarkOptions): string {
    const label: string = options.text.trim();
    if (label !== '') {
      return options.showTimestamp ? `${label}  ${options.timestamp}` : label;
    }
    return options.showTimestamp ? options.timestamp : '';
  }

  /** 判断颜色是否为深色（用于自动选择对比色） */
  private static isDarkColor(hex: string): boolean {
    let value: string = hex.replace('#', '');
    if (value.length !== 6) {
      return false;
    }
    const r: number = parseInt(value.substring(0, 2), 16);
    const g: number = parseInt(value.substring(2, 4), 16);
    const b: number = parseInt(value.substring(4, 6), 16);
    return (r * 299 + g * 587 + b * 114) / 1000 < 128;
  }

  /**
   * 将 PixelMap 编码为 JPEG 字节流
   */
  static async packJpeg(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const options: image.PackingOption = {
        format: 'image/jpeg',
        quality: 95
      };
      return await packer.packToData(pixelMap, options);
    } finally {
      await packer.release();
    }
  }

  /**
   * 将字节流写入应用沙箱子目录，返回文件绝对路径。
   * 沙箱无需任何存储权限；卸载应用时随之删除。
   */
  static saveBytesToSandbox(
    context: common.UIAbilityContext,
    bytes: Uint8Array,
    subDir: string,
    fileName: string
  ): string {
    const dir: string = `${context.filesDir}/photos/${subDir}`;
    // 目录已存在时 mkdirSync 会抛 "File exists"，必须先判断
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const filePath: string = `${dir}/${fileName}`;
    const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer);
    } finally {
      fs.closeSync(file);
    }
    return filePath;
  }
}
